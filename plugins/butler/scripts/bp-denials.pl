#!/usr/bin/env perl
# bp-denials.pl -- `summary` reader over denials.jsonl (never-halt package 06,
# specs/06-prompt-watch-spec.md sec 2.9). The only accepted argv is exactly
# `summary`; any other argv prints a usage line to stderr and exits 2. Never
# writes anything; a missing data dir or file is simply zero records.
use strict;
use warnings;
use FindBin qw($Bin);
use JSON::PP ();
use B qw(svref_2object SVp_POK);

require "$Bin/BpDataRoot.pm";
require "$Bin/BpHook/PromptWatch.pm";

sub _is_plain_string {
    my ($v) = @_;
    return 0 unless defined $v;
    return 0 if ref $v;
    my $flags = svref_2object(\$v)->FLAGS;
    return ($flags & SVp_POK()) ? 1 : 0;
}

sub _agent_label {
    my ($rec) = @_;
    my $v = $rec->{agent_id};
    return (_is_plain_string($v) && length $v) ? $v : '?';
}

sub _command_label {
    my ($rec) = @_;
    my $tool_name = $rec->{tool_name};
    my $tn_ok = _is_plain_string($tool_name) && length $tool_name;

    if ($tn_ok && $tool_name eq 'Bash') {
        my $ti = $rec->{tool_input};
        return 'Bash ?' unless _is_plain_string($ti);
        (my $stripped = $ti) =~ s/\A\s+//;
        my ($word) = $stripped =~ /\A(\S+)/;
        return defined $word ? "Bash $word" : 'Bash (empty)';
    }

    return $tn_ok ? $tool_name : '?';
}

sub main {
    my @argv = @_;
    unless (@argv == 1 && $argv[0] eq 'summary') {
        print STDERR "usage: bp-denials summary\n";
        return 2;
    }

    my $data = BpDataRoot::data_dir();
    my $recs = (defined $data && length $data)
        ? BpHook::PromptWatch::read_records("$data/.drive-solo/denials.jsonl")
        : [];
    $recs = [] unless ref $recs eq 'ARRAY';

    my %by_agent;
    my %by_command;
    for my $rec (@$recs) {
        next unless ref $rec eq 'HASH';
        $by_agent{ _agent_label($rec) }++;
        $by_command{ _command_label($rec) }++;
    }

    my @out;
    push @out, sprintf('denials: %d', scalar @$recs);
    push @out, 'by agent:';
    for my $k (sort { $by_agent{$b} <=> $by_agent{$a} || $a cmp $b } keys %by_agent) {
        push @out, sprintf('  %d %s', $by_agent{$k}, $k);
    }
    push @out, 'by command:';
    for my $k (sort { $by_command{$b} <=> $by_command{$a} || $a cmp $b } keys %by_command) {
        push @out, sprintf('  %d %s', $by_command{$k}, $k);
    }

    binmode(STDOUT, ':utf8');
    print STDOUT join("\n", @out) . "\n";
    return 0;
}

exit(main(@ARGV)) unless caller;
1;
