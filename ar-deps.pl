#!/usr/bin/perl

use v5.12;
use warnings;

use File::Basename;
use IPC::Open2;
use List::Util qw(min);
use Getopt::Long;

sub usage {
    "$0 [ --dot=<output.dot> ] [ --sccs=<output> ] <library.a>\n" .
    "if neither --dot nor --sccs is given, defaults to --sccs=- (stdout)\n"
}

main();

sub main {
    my $dot_fn;
    my $scc_fn;
    GetOptions (
        "dot=s"  => \$dot_fn,
        "sccs=s"  => \$scc_fn,
    ) or die usage();

    if (! defined $dot_fn && ! defined $scc_fn) {
        $scc_fn = "-";
    }

    die usage() unless @ARGV == 1;

    my $ar_fn = shift @ARGV;

    my ($V, $E) = parse_ar_file($ar_fn);

    if (defined $dot_fn) {
        write_dot($dot_fn, $V, $E, $ar_fn);
    }

    if (defined $scc_fn) {
        write_sccs($scc_fn, $V, $E);
    }
}

sub pretty_sym {
    my $sym = shift @_;

=pod
    state $cppfilt_pid;
    state $cppfilt_in;
    state $cppfilt_out;
    if (! defined $cppfilt_pid) {
        open2($cppfilt_out, $cppfilt_in, '/usr/bin/c++filt')
            or die $!;
    }
    END {
        waitpid $cppfilt_pid, 0
            if defined $cppfilt_pid;
    }


    local $| = 1;
    say $cppfilt_in $sym;
    return <$cppfilt_out>;
=cut
    chomp(my $pretty = qx{c++filt $sym});
    return $pretty;
}

sub parse_ar_file {
    my $ar_fn = shift;

    open my $ar_nm_out, "-|", qw{ /usr/bin/nm -og }, $ar_fn
        or die "Failed to execute nm -og $ar_fn: $!\n";

    my %obj_needs;
    my %obj_provides;

    my %sym_provided_by;
    #my %sym_needed_by;

    my $add_obj_sym = sub {
        my ($sym_type, $obj_fn, $sym_name) = @_;

        if ($sym_type =~ /^[u]$/i) {
            push @{$obj_needs{$obj_fn}}, $sym_name;
            #        push @{$sym_needed_by{$sym_name}}, $obj_fn;
        }
        elsif ($sym_type =~ /^[vw]$/i) {
            # weak symbol, ignore
            warn ": ignoring weak symbol ", pretty_sym($sym_name), " in $obj_fn\n";
        }
        else {
            push @{$obj_provides{$obj_fn}}, $sym_name;
            warn "Duplicate symbol ", pretty_sym($sym_name), ":\n$sym_provided_by{$sym_name}, $obj_fn (type $sym_type)\n"
                if exists $sym_provided_by{$sym_name};
            $sym_provided_by{$sym_name} = $obj_fn;
        }
    };

    while (my $ln = <$ar_nm_out>) {
        chomp $ln;
        my ($ar_path, $obj_fn, $sym_ln) = split /:/, $ln, 3;
        my ($sym_value, $sym_type, $sym_name) = split /\s+/, $sym_ln, 3;
        die "Failed to parse:\n$ln"
            unless $sym_type =~ /^[a-zA-Z?-]$/;

        $add_obj_sym->($sym_type, $obj_fn, $sym_name);
    }

# Create vertices
    my %objs;
    @objs{keys %obj_needs} = (1) x keys %obj_needs;
    @objs{keys %obj_provides} = (1) x keys %obj_provides;

    my @V = keys %objs;

# Create edges
    my %obj_needs_objs;

    while (my ($needy_obj, $syms) = each %obj_needs) {
        for my $sym (@$syms) {
            my $providing_obj = $sym_provided_by{$sym};
            # may be external
            if (defined $providing_obj) {
                push @{$obj_needs_objs{$needy_obj}}, $providing_obj;
            }
        }
    }

# make edges unique
    while (my ($needy_obj, $providing_objs) = each %obj_needs_objs) {
        my %objs;
        @objs{@$providing_objs} = ();
        @$providing_objs = keys %objs;
    }

    return \@V, \%obj_needs_objs;
}

sub write_dot {
    my ($dot_fn, $V, $E, $ar_fn) = @_;

    my $fh = openFileW($dot_fn);

    say $fh 'digraph "', basename($ar_fn), '" {';
    for my $v (@$V) {
        say $fh qq("$v";);
    }
    while (my ($v, $ws) = each %$E) {
        for my $w (@$ws) {
            say $fh qq("$v" -> "$w";);
        }
    }
    say $fh "}";
}

sub write_sccs {
    my ($scc_fn, $V, $E) = @_;

    my $fh = openFileW($scc_fn);

    my @sccs = tarjan_scc($V, $E);

    for my $scc (@sccs) {
        say $fh "@$scc";
    }
}

sub openFileW {
    my $fn = shift;
    return *STDOUT if $fn eq "-";

    open my $fh, ">", $fn
        or die $!;

    return $fh;
}

=pod
Takes an array-ref of vertices (strings)
and an hash-ref of edges, indexed by vertex, each entry containing an array of
neighbours.

Returns SCCs in reverse topological order.
=cut
sub tarjan_scc {
    my ($V, $E) = @_;

    my $index = 0;
    my @S;
# %index_of is a map vertex => index, which assigns indexes in dfs preorder
    my %index_of;
# %lowlink_of is a map vertex => index, which assigns the earliest visited
# vertex that can be reached from the dfs subtree rooted with the vertex
    my %lowlink_of;
    my %onstack;

    # uses and modifies outer variables!
    # returns a list of strongly connected components
    my $strongconnect;
    $strongconnect = sub {
        my ($v) = @_;
        $index_of{$v} = $index;
        $lowlink_of{$v} = $index;
        ++$index;
        push @S, $v;
        $onstack{$v} = 1;

        # result
        my @sccs;

        for my $w (@{ $E->{$v} }) {
            if (! exists $index_of{$w}) {
                push @sccs, $strongconnect->($w);
                $lowlink_of{$v} = min(@lowlink_of{$v, $w});
            }
            elsif ($onstack{$w}) {
                $lowlink_of{$v} = min($lowlink_of{$v}, $index_of{$w});
            }
        }

        if ($lowlink_of{$v} == $index_of{$v}) {
            my @scc;
            my $w;
            while ($S[-1] ne $v) {
                $w = pop @S;
                delete $onstack{$w};
                push @scc, $w;
            }
            $w = pop @S;
            die unless $w eq $v;
            delete $onstack{$w};
            push @scc, $w;

            push @sccs, \@scc;
        }

        return @sccs;
    };

    my @sccs;

    for my $v (@$V) {
        if (! exists $index_of{$v}) {
            my @res = $strongconnect->($v);
            push @sccs, @res;
        }
    }

    return @sccs;
}
