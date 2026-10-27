package vimgit;

use strict;
use FileHandle;
use File::Basename;
use Data::Dumper;

use vimgit::history;
use vimgit::git;
use vimgit::lang;
use vimgit::workspace;

sub new
{
  my $class = shift;

  my $self = bless 
               { 
                 history => 'vimgit::history'->new (), 
                 maxfind => 200,
                 @_ 
               }, $class;

# ROOT : the workspace directory (the current directory)

  $self->{workspace} ||= 'vimgit::workspace'->new (root => $self->{ROOT})
    if ($self->{ROOT});

  return $self;
}

sub windex_
{

# find words in file and build index

  my $f = shift;
  my $b = shift;

  my @w = map { lc ($_) } ($_[0] =~ m/\b([a-z][a-z_0-9]+|\d\d\d+)\b/igoms);
  for my $w (@w) 
    {
      push @{ $b->{$w} }, $f;
    }
}

sub wanted_windex_
{

# helper function to build indexes
# windex : word index
# sindex : file location index
# file : path recorded in the indexes; root : directory it is relative to

  my %args = @_;

  my $windex   = $args{windex};
  my $sindex   = $args{sindex};
  my $fhlog    = $args{fhlog};
  my $callback = $args{callback};
  my $f = $args{file};
  my $p = defined ($args{root}) ? "$args{root}/$f" : $f;

# skip non file elements
  return unless (-f $p);
  return if ($f =~ m/\.vimgit\b/o);

  $f =~ s,^\./,,o;

  if ($sindex)
    {
      push @{ $sindex->{&basename ($f)} }, $f;
    }

# fortran & C & C++
  return unless ($f =~ 'vimgit::lang'->indexed ());

  $callback && $callback->($f);

  $fhlog && $fhlog->print ("$f\n");

  my $text;

  if ($windex || $args{dindex})
    {
      $text = do { my $fh = 'FileHandle'->new ("<$p"); local $/ = undef; <$fh> };
    }

  &windex_ ($f, $windex, $text) if ($windex);

# dindex : definitions, name -> [ "file:line" ], "file:line*" for contained routines;
# cindex : routines called, "file:line" -> [ name ]

  if ($args{dindex} && ('vimgit::lang'->lang ($f) eq 'fortran'))
    {
      for my $u (@{ 'vimgit::lang::fortran'->units ($text, fixed => (($f =~ m/\.f$/io) ? 1 : 0)) })
        {
          my $key = "$f:$u->{line}";
          push @{ $args{dindex}{$u->{name}} }, $key . ($u->{internal} ? '*' : '');
          $args{cindex}{$key} = $u->{calls};
        }
    }
}

sub cidx
{
  my ($lh, $sh) = @_;

# transform list values in strings

  while (my ($key, $val) = each (%$lh))
    {
      my %seen;
      my @val = grep { ! $seen{$_}++ } @{$val};
      $sh->{$key} = join (' ', @val);
    }
}
  
1;
