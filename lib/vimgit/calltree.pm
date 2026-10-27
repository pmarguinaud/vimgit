package vimgit::calltree;

# call tree buffers : a routine and the routines it calls (:CT), or the routines calling it
# (:CTR), one per line, drawn with lines :
#
# CPG
# ├── CPG_GP
# │   └── ABOR1 [+9]
# ├── CPG_DYN_SLG (see line 12)
# └── YDCPG_SL1AUX%SET (type-bound)
#
# trees of callers are drawn from right to left, each caller on the left of the routine it
# calls :
#
#                  RAIN_ICE
#      ARO_RAIN_ICE ──┘
# APL_AROME_MICRO ──┘
#
# the definition of the routine of each line is in a file next to the tree (.loc instead
# of .txt), one line per line of the tree, empty when there is none

use strict;

use File::Basename;
use File::Path;
use FileHandle;
use List::Util qw (max);

use base qw (vimgit::file);

# branches of the tree; the strings are UTF-8 bytes, as vim gives them

our ($TEE, $ELL, $BAR, $GAP) = ('├── ', '└── ', '│   ', '    ');

# same, from right to left

our %MIRROR = ($TEE => ' ──┤', $ELL => ' ──┘', $BAR => '   │', $GAP => '    ');

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

sub locfile
{
  my $f = shift;
  $f =~ s/\.txt$/.loc/o;
  return $f;
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

# lines : [ depth, name, note, location ]; first : definition -> line where it is expanded;
# onpath : definitions being expanded (recursion)

  my (@line, %first, %onpath);

  my $walk;
  $walk = sub
  {
    no warnings 'recursion';

    my ($d, $level, $others) = @_;

    if (my $l = $first{$d->{key}})
      {
        push @line, [ $level, $d->{name}, ($onpath{$d->{key}} ? "(recursive, see line $l)" : "(see line $l)"),
                      "$d->{file}:$d->{line}" ];
        return;
      }

    push @line, [ $level, $d->{name}, ($others ? "[+$others]" : ''), "$d->{file}:$d->{line}" ];
    $first{$d->{key}} = scalar (@line);

    my @child = $callers ? (grep { ! $ws->blacklisted ($_->{name}) } $ws->callers ($d->{name}))
                         : (grep { ! $ws->blacklisted ($_) } $ws->callees ($d));

    if (defined ($depth) && ($level >= $depth))
      {
        $line[-1][2] = join (' ', grep { $_ } $line[-1][2], '...') if (@child);
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
                push @line, [ $level + 1, $name, '(type-bound)', '' ];
                next;
              }
            my @d = $ws->definitions ($name, caller => $d);
            unless (@d)
              {
                push @line, [ $level + 1, $name, '(not found)', '' ];
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

# branches, from the last line up : more[k], a line of depth k follows before the end of
# the subtree of depth k - 1

  my @more;
  for my $L (reverse (@line))
    {
      my $l = $L->[0];
      my $prefix = '';
      if ($l > 0)
        {
          my @b = ((map { $more[$_] ? $BAR : $GAP } (1 .. $l - 1)), ($more[$l] ? $TEE : $ELL));
          $prefix = join ('', $callers ? (map { $MIRROR{$_} } reverse (@b)) : @b);
        }
      $#more = $l;
      $more[$l] = 1;
      push @$L, $prefix;
    }

# from right to left : the notes on the left, lines aligned on the right (a branch is 4
# characters)

  my $width = &max (map { length (uc ($_->[1]) . ($_->[2] ? " $_->[2]" : '')) + 4 * $_->[0] } @line);

  my $fh = 'FileHandle'->new (">$filename");
  my $fl = 'FileHandle'->new ('>' . &locfile ($filename));
  for (@line)
    {
      my ($l, $name, $note, $loc, $prefix) = @$_;
      if ($callers)
        {
          my $s = ($note ? "$note " : '') . uc ($name);
          $fh->print ((' ' x ($width - length ($s) - 4 * $l)) . $s . $prefix . "\n");
        }
      else
        {
          $fh->print ($prefix . uc ($name) . ($note ? " $note" : '') . "\n");
        }
      $fl->print ("$loc\n");
    }
  $fh->close ();
  $fl->close ();

# a buffer holding a previous tree is replaced; folding by depth : a branch is 4 characters

  &VIM::DoCommand ("silent! bwipeout $filename");
  &VIM::DoCommand ("silent view $filename");
  &VIM::DoCommand ('setlocal foldmethod=expr foldlevel=99 nowrap');
  &VIM::DoCommand ($callers ? q(let &l:foldexpr = "strchars(matchstr(getline(v:lnum), '[│┤┘─ ]*$'))/4")
                            : q(let &l:foldexpr = "strchars(matchstr(getline(v:lnum), '^[│├└─ ]*'))/4"));

  &VIM::Msg (sprintf ("%s %s: %d lines, %d routines", ($callers ? 'Callers of' : 'Call tree of'), uc ($word),
                      scalar (@line), scalar (keys (%first))));

  return $class->new (file => $filename);
}

sub parse_
{

# name and note of a line of a tree; the note is between columns $from and $to

  my ($line, $callers) = @_;

  if ($callers)
    {
      my ($blank, $note, $name) = ($line =~ m/^(\s*)(.*?)\s*(\S+)(?:$MIRROR{$TEE}|$MIRROR{$ELL}|$MIRROR{$BAR}|$GAP)*\s*$/)
        or return;
      return (name => $name, note => $note, from => length ($blank), to => length ($blank . $note));
    }

  my ($prefix, $name, $note) = ($line =~ m/^((?:$BAR|$GAP|$TEE|$ELL)*)(\S+)\s*(.*?)\s*$/) or return;
  return (name => $name, note => $note, from => length ($prefix . $name) + 1, to => length ($line));
}

sub locations_
{
  my $self = shift;
  my $fh = 'FileHandle'->new ('<' . &locfile ($self->{file})) or return ();
  chomp (my @loc = <$fh>);
  return @loc;
}

sub do_find
{

# <TAB> : on a name, search the name; ² : on a name, open the definition (pick list for
# [+n]); both keys on "see line N" : go to line N

  my ($self, %args) = @_;

  my $edtr = $args{editor};
  my $hist = $args{hist};

  my $curbuf = $edtr->getcurbuf ();
  my ($row, $col) = $edtr->getcurwin ()->Cursor ();
  my ($line) = $curbuf->Get ($row);

  my %l = &parse_ ($line, $self->{file} =~ m/\.callers/o) or return;

  if (($col >= $l{from}) && ($col <= $l{to}) && ($l{note} =~ m/see line (\d+)/o))
    {
      return &VIM::DoCommand (":$1");
    }

  unless ($args{defn})
    {
      return $edtr->find (word => $l{name}, hist => $hist);
    }

  my $target = ($self->locations_ ())[$row - 1];

  return &VIM::Msg ("No definition for $l{name}") unless ($target);

# several definitions : the one of the tree first, then the others

  if ($l{note} =~ m/\[\+\d+\]/o)
    {
      my $ws = $edtr->{workspace};
      $ws->refresh ();
      my @P = ($target, grep { $_ ne $target } map { "$_->{file}:$_->{line}" } $ws->definitions (lc ($l{name})));
      $target = $edtr->pick (@P) or return;
    }

  return $edtr->edit (files => [ $target ], hist => $hist);
}

1;
