package vimgit::calltree;

# call tree buffers : a routine and the routines it calls (:CT), or the routines calling it
# (:CTR), one per line, indented by depth, with the location of the definition :
#
# CPG                                     ial-source/arpifs/adiab/cpg.F90:1
#   CPG_GP                                ial-source/arpifs/adiab/cpg_gp.F90:1
#     ABOR1                               ial-source/scmec/dummy/abor1.F90:1 [+9]
#   CPG_DYN_SLG                           (see line 12)
#   YDCPG_SL1AUX%SET                      % type-bound, not resolved

use strict;

use File::Basename;
use File::Path;
use FileHandle;
use List::Util qw (max);

use base qw (vimgit::file);

# column of the locations

our $COLUMN = 40;

sub new
{
  my $class = shift;
  my $self = bless { @_ }, $class;
  return $self;
}

sub filename
{
  my ($class, %args) = @_;
  my $f = "$args{editor}{TOP}/calltree=/" . lc ($args{word});
  $f .= '.callers' if ($args{callers});
  $f .= ".depth=$args{depth}" if (defined ($args{depth}));
  return "$f.txt";
}

sub create
{

# build the tree of routine $args{word}, write it, open it; depth : levels shown below the
# routine; callers : routines calling it instead of routines it calls

  my ($class, %args) = @_;

  my $edtr    = $args{editor};
  my $ws      = $edtr->{workspace};
  my $word    = lc ($args{word});
  my $depth   = $args{depth};
  my $callers = $args{callers};

  unless ($ws->refresh ())
    {
      &VIM::Msg ('The indexes have no call information: run vimgit -i');
      return;
    }

  my @root = $ws->definitions ($word);

  unless (@root)
    {
      &VIM::Msg ("`$word' definition was not found");
      return;
    }

# lines : [ depth, name, location ]; first : definition -> line where it is expanded;
# onpath : definitions being expanded (recursion)

  my (@line, %first, %onpath);

  my $walk;
  $walk = sub
  {
    no warnings 'recursion';

    my ($d, $level, $others) = @_;

    if (my $l = $first{$d->{key}})
      {
        push @line, [ $level, $d->{name}, ($onpath{$d->{key}} ? "(recursive, see line $l)" : "(see line $l)") ];
        return;
      }

    push @line, [ $level, $d->{name}, "$d->{file}:$d->{line}" . ($others ? " [+$others]" : '') ];
    $first{$d->{key}} = scalar (@line);

    my @child = $callers ? (grep { ! $ws->blacklisted ($_->{name}) } $ws->callers ($d->{name}))
                         : (grep { ! $ws->blacklisted ($_) } $ws->callees ($d));

    if (defined ($depth) && ($level >= $depth))
      {
        $line[-1][2] .= '  ...' if (@child);
        return;
      }

    $onpath{$d->{key}} = 1;

    if ($callers)
      {
        $walk->($_, $level + 1, 0) for (@child);
      }
    else
      {
        my %seen;
        for my $name (grep { ! $seen{$_}++ } @child)
          {
            if ($name =~ m/%/o)
              {
                push @line, [ $level + 1, $name, '% type-bound, not resolved' ];
                next;
              }
            my @d = $ws->definitions ($name, caller => $d);
            unless (@d)
              {
                push @line, [ $level + 1, $name, '? not found' ];
                next;
              }
            $walk->($d[0], $level + 1, scalar (@d) - 1);
          }
      }

    delete $onpath{$d->{key}};
  };

  $walk->($root[0], 0, scalar (@root) - 1);

  my $filename = $class->filename (%args);
  &mkpath (&dirname ($filename));

  my $fh = 'FileHandle'->new (">$filename");
  for (@line)
    {
      my ($l, $name, $loc) = @$_;
      my $s = ('  ' x $l) . uc ($name);
      $fh->print ($s . (' ' x &max (2, $COLUMN - length ($s))) . "$loc\n");
    }
  $fh->close ();

# a buffer holding a previous tree is replaced; folding by indentation

  &VIM::DoCommand ("silent! bwipeout $filename");
  &VIM::DoCommand ("silent view $filename");
  &VIM::DoCommand ('setlocal foldmethod=indent shiftwidth=2 foldlevel=99 nowrap');

  &VIM::Msg (sprintf ("%s %s: %d lines, %d routines", ($callers ? 'Callers of' : 'Call tree of'), uc ($word),
                      scalar (@line), scalar (keys (%first))));

  return $class->new (file => $filename);
}

sub parse_
{

# indentation, name and location of a line of a tree; location starts at column $start

  my $line = shift;
  my ($indent, $name, $gap, $loc) = ($line =~ m/^( *)(\S+)(\s+)(.*?)\s*$/o) or return;
  return (name => $name, loc => $loc, start => length ($indent . $name . $gap));
}

sub do_find
{

# <TAB> : on a name, search the name; ² : on a name, open the definition (pick list for
# [+n]); both keys on a location : open the file at that line, or go to "see line N"

  my ($self, %args) = @_;

  my $edtr = $args{editor};
  my $hist = $args{hist};

  my $curbuf = $edtr->getcurbuf ();
  my ($row, $col) = $edtr->getcurwin ()->Cursor ();
  my ($line) = $curbuf->Get ($row);

  my %l = &parse_ ($line) or return;

# location of the definition : on this line, or on the line it refers to

  my ($target, $see) = ($l{loc} =~ m/^(\S+:\d+)/o);
  if ($l{loc} =~ m/see line (\d+)/o)
    {
      $see = $1;
      my %r = &parse_ (($curbuf->Get ($see))[0]);
      ($target) = (($r{loc} || '') =~ m/^(\S+:\d+)/o);
    }

  if ($col >= $l{start})
    {
      return &VIM::DoCommand (":$see") if ($see);
      return $edtr->edit (files => [ $target ], hist => $hist) if ($target);
      return &VIM::Msg ("No definition for $l{name}");
    }

  unless ($args{defn})
    {
      my ($word) = &vimgit::tools::findword ($col, $line);
      return $edtr->find (word => $word, hist => $hist) if ($word);
      return;
    }

  return &VIM::Msg ("No definition for $l{name}") unless ($target);

# several definitions : the one of the tree first, then the others

  if ($l{loc} =~ m/\[\+\d+\]/o)
    {
      my $ws = $edtr->{workspace};
      $ws->refresh ();
      my @P = ($target, grep { $_ ne $target } map { "$_->{file}:$_->{line}" } $ws->definitions (lc ($l{name})));
      $target = $edtr->pick (@P) or return;
    }

  return $edtr->edit (files => [ $target ], hist => $hist);
}

1;
