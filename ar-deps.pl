#!/usr/bin/perl

use v5.12;
use warnings;

use File::Basename;
use IPC::Open2;
use List::Util qw(min any);
use Getopt::Long;

sub usage {
    "$0 [ --dot=<output.dot> ] [ --sccs=<output> ] [ --print-external-dependencies ] <library.a> [ <another-library.a> ... ]\n" .
    "if neither --dot nor --sccs is given, defaults to --sccs=- (stdout)\n"
}

# TODO an option that does subgraphs based on the libraries, rather than the
# sccs, might be nice.

main();

sub main {
    my $dot_fn;
    my $scc_fn;
    my $opts = {
        print_external_deps => '',
    };
    GetOptions (
        "dot=s"  => \$dot_fn,
        "sccs=s"  => \$scc_fn,
        "print-external-dependencies"  => \$opts->{print_external_deps},
    ) or die usage();

    if (! defined $dot_fn && ! defined $scc_fn) {
        $scc_fn = "-";
    }

    die usage() unless @ARGV >= 1;

    my @libraries = @ARGV;
    @ARGV = ();

    my (%obj_files, %obj_needs, %obj_provides, %sym_provided_by);

    for my $ar_fn (@libraries) {
        # TODO Maybe its better to parse the (possibly non-empty) result hashes
        # via reference to parse_ar_file, so it can handle duplicates directly.
        my ($loc_obj_files, $loc_obj_needs, $loc_obj_provides, $loc_sym_provided_by)
            = parse_ar_file($ar_fn, $opts);

        die "Object file(s) with the same name already encountered, when reading $ar_fn: "
            . join ", ", grep { exists $obj_files{$_} } keys %$loc_obj_files
            if any { exists $obj_files{$_} } keys %$loc_obj_files;
        @obj_files{keys %$loc_obj_files} = values %$loc_obj_files;

        die "Object file with the same name already encountered, when reading $ar_fn"
            if any { exists $obj_needs{$_} } keys %$loc_obj_needs;
        @obj_needs{keys %$loc_obj_needs} = values %$loc_obj_needs;

        die "Object file with the same name already encountered, when reading $ar_fn"
            if any { exists $obj_provides{$_} } keys %$loc_obj_provides;
        @obj_provides{keys %$loc_obj_provides} = values %$loc_obj_provides;

        die "Symbol already encountered, when reading $ar_fn"
            if any { exists $sym_provided_by{$_} } keys %$loc_sym_provided_by;
        @sym_provided_by{keys %$loc_sym_provided_by} = values %$loc_sym_provided_by;
    }

    my ($V, $E) = create_graph(\%obj_files, \%obj_needs, \%obj_provides, \%sym_provided_by, $opts);

    if (defined $dot_fn) {
        my $graph_name = join ",", map basename($_), @libraries;
        write_dot($dot_fn, $V, $E, $graph_name);
    }

    if (defined $scc_fn) {
        write_sccs($scc_fn, $V, $E);
    }
}

sub pretty_sym {
    my $sym = shift @_;
    chomp(my $pretty = qx{c++filt $sym});
    die "c++filt error" unless $? == 0;
    return $pretty;
}

sub parse_ar_file {
    my ($ar_fn, $opts) = @_;

    open my $ar_nm_out, "-|", qw{ /usr/bin/nm -og }, $ar_fn
        or die "Failed to execute nm -og $ar_fn: $!\n";

    my %obj_needs;
    my %obj_provides;

    my %sym_provided_by;
    #my %sym_needed_by;

    my $add_obj_sym = sub {
        my ($sym_type, $obj_id, $sym_name) = @_;

        if ($sym_type =~ /^[u]$/i) {
            push @{$obj_needs{$obj_id}}, $sym_name;
            #push @{$sym_needed_by{$sym_name}}, $obj_id;
        }
        elsif ($sym_type =~ /^[vw]$/i) {
            # weak symbol, ignore
            #warn ": ignoring weak symbol ", pretty_sym($sym_name), " in $obj_id\n";
        }
        else {
            push @{$obj_provides{$obj_id}}, $sym_name;
            warn "Duplicate symbol ", pretty_sym($sym_name), ":\n$sym_provided_by{$sym_name}, $obj_id (type $sym_type)\n"
                if exists $sym_provided_by{$sym_name};
            $sym_provided_by{$sym_name} = $obj_id;
        }
    };

    my %obj_files;

    while (my $ln = <$ar_nm_out>) {
        chomp $ln;
        my ($ar_path, $obj_fn, $sym_ln) = split /:/, $ln, 3;
        # Try to make object file names a little more unique, as there may be
        # different object files with the same name. This is harder if it
        # happens in the same archive...
        my $obj_id = join "/", basename($ar_path), $obj_fn;
        $obj_files{$obj_id} = 1;
        my ($sym_value, $sym_type, $sym_name) = split /\s+/, $sym_ln, 3;
        die "Failed to parse:\n$ln"
            unless $sym_type =~ /^[a-zA-Z?-]$/;

        $add_obj_sym->($sym_type, $obj_id, $sym_name);
    }

    return (\%obj_files, \%obj_needs, \%obj_provides, \%sym_provided_by);
}

sub create_graph {
    my ($obj_files, $obj_needs, $obj_provides, $sym_provided_by, $opts) = @_;

# Create vertices
    my @V = do {
        if ($opts->{print_external_deps}) {
            my %all_objs = %$obj_files;
            @all_objs{keys %$obj_needs} = (1) x keys %$obj_needs;
            @all_objs{keys %$obj_provides} = (1) x keys %$obj_provides;

            keys %all_objs # sic
        } else {
            keys %$obj_files # sic
        }
    };

# Create edges
    my %obj_needs_objs;

    while (my ($needy_obj, $syms) = each %$obj_needs) {
        for my $sym (@$syms) {
            my $providing_obj = $sym_provided_by->{$sym};
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
    my ($dot_fn, $V, $E, $graph_name) = @_;

    my $fh = openFileW($dot_fn);

    my @sccs = tarjan_scc($V, $E);

    say $fh qq(strict digraph "$graph_name" {);
    say $fh 'rankdir BT';

    my $i = 0;
    for my $scc (@sccs) {
        ++$i;
        say $fh "subgraph cluster$i {"
            if @$scc > 1;
        for my $v (@$scc) {
            say $fh qq("$v";);
        }
        say $fh "}"
            if @$scc > 1;
    }

    while (my ($v, $ws) = each %$E) {
        say $fh qq("$v" -> {), join(" ", map qq("$_"), @$ws), '};';
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
            push @sccs, $strongconnect->($v);
        }
    }

    return @sccs;
}
