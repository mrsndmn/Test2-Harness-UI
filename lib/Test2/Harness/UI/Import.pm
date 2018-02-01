package Test2::Harness::UI::Import;
use strict;
use warnings;

use DateTime;

use Carp qw/croak/;

use Test2::Harness::Util::JSON qw/encode_json/;

use Test2::Harness::UI::Util::HashBase qw/-schema/;

sub init {
    my $self = shift;

    croak "'schema' is a required attribute"
        unless $self->{+SCHEMA};
}

sub import_events {
    my $self = shift;
    my ($key, $payload) = @_;

    my $schema = $self->{+SCHEMA};
    $schema->txn_begin;

    my $out;
    my $ok = eval { $out = $self->process_params($key, $payload); 1 };
    my $err = $@;

    if (!$ok) {
        warn $@;
        $schema->txn_rollback;
        die $err;
    }

    if   ($out->{success}) { $schema->txn_commit }
    else                   { $schema->txn_rollback }

    return $out;
}

sub process_params {
    my $self = shift;
    my ($key, $payload) = @_;

    # Verify or create feed
    my ($feed, $error) = $self->find_feed($key, $payload);
    return $error if $error;

    my $cnt = 0;
    for my $event (@{$payload->{events}}) {
        my $error = $self->import_event($feed, $event);
        return {errors => ["error processing event number $cnt: $error"]} if $error;
        $cnt++;
    }

    return {success => 1, events_added => $cnt, feed => $feed->feed_ui_id};
}

sub find_feed {
    my $self = shift;
    my ($key, $payload) = @_;

    my $perms = $payload->{permissions} || 'private';

    my $schema = $self->{+SCHEMA};

    # New feed!
    my $feed_ui_id = $payload->{feed}
        or return $schema->resultset('Feed')->create({api_key_ui_id => $key->api_key_ui_id, user_ui_id => $key->user_ui_id, permissions => $perms});

    # Verify existing feed

    my $feed = $schema->resultset('Feed')->find({feed_ui_id => $feed_ui_id});

    return (undef, {errors => ["Invalid feed"]}) unless $feed && $feed->user_ui_id == $key->user_ui_id;

    return (undef, {errors => ["permissions ($perms) do not match established permissions (" . $feed->permissions . ") for this feed ($feed_ui_id)"]})
        unless $feed->permissions eq $perms;

    return $feed;
}

sub format_stamp {
    my $stamp = shift;
    return undef unless $stamp;
    return DateTime->from_epoch(epoch => $stamp);
}

sub vivify_row {
    my $self = shift;
    my ($type, $field, $find, $create) = @_;

    return (undef, "No $field provided") unless defined $find->{$field};

    my $schema = $self->{+SCHEMA};
    my $row = $schema->resultset($type)->find($find);
    return $row if $row;

    return $schema->resultset($type)->create({%$find, %$create}) || die "Unable to find/add $type: $find->{$field}";
}

sub unique_row {
    my $self = shift;
    my ($type, $field, $find, $create) = @_;

    return (undef, "No $field provided") unless defined $find->{$field};

    my $schema = $self->{+SCHEMA};
    return (undef, "Duplicate $type") if $schema->resultset($type)->find($find);
    return $schema->resultset($type)->create({%$find, %$create}) || die "Could not create $type";
}

sub import_event {
    my $self = shift;
    my ($feed, $event_data) = @_;

    my ($run, $run_error) = $self->vivify_row(
        'Run' => 'run_id',
        {feed_ui_id  => $feed->feed_ui_id, run_id => $event_data->{run_id}},
        {permissions => $feed->permissions},
    );
    return $run_error if $run_error;

    my ($job, $job_error) = $self->vivify_row(
        'Job' => 'job_id',
        {run_ui_id   => $run->run_ui_id, job_id => $event_data->{job_id}},
        {permissions => $feed->permissions},
    );
    return $job_error if $job_error;

    return "No event_id provided" unless $event_data->{event_id};

    my ($event, $error) = $self->unique_row(
        'Event' => 'event_id',
        {job_ui_id => $job->job_ui_id,                    event_id => $event_data->{event_id}},
        {stamp     => format_stamp($event_data->{stamp}), stream_id => $event_data->{stream_id}},
    );
    return $error if $error;

    return $self->import_facets($event, $event_data->{facet_data});
}

sub import_facets {
    my $self = shift;
    my ($event, $facets) = @_;

    return unless $facets;

    for my $facet_name (keys %$facets) {
        my $val = $facets->{$facet_name} or next;

        unless (ref($val) eq 'ARRAY') {
            $self->import_facet($event, $facet_name, $val);
            next;
        }

        $self->import_facet($event, $facet_name, $_) for @$val;
    }

    return;
}

sub import_facet {
    my $self = shift;
    my ($event, $facet_name, $val) = @_;

    my $schema = $self->{+SCHEMA};

    my $facet = $schema->resultset('Facet')->create(
        {
            event_ui_id => $event->event_ui_id,
            facet_name  => $facet_name,
            facet_value => encode_json($val),
        }
    );
    die "Could not add facet '$facet_name'" unless $facet;

    if ($facet_name eq 'harness_run') {
        my $run = $event->run;
        $run->update({facet_ui_id => $facet->facet_ui_id}) unless $run->facet_ui_id;
    }
    elsif ($facet_name eq 'harness_job') {
        my $job = $event->job;
        $job->update({job_facet_ui_id => $facet->facet_ui_id}) unless $job->job_facet_ui_id;
    }
    elsif ($facet_name eq 'harness_job_end') {
        my $job = $event->job;
        $job->update({end_facet_ui_id => $facet->facet_ui_id, file => $val->{file}, fail => $val->{fail}}) unless $job->end_facet_ui_id;
    }

    return $facet;
}

1;
