package vimgit;

use strict;
use DB_File;
use FileHandle;
use Fcntl qw (O_RDWR O_CREAT);
use File::Find qw ();
use File::Basename;
use Data::Dumper;
use File::Path;

use vimgit::history;
use vimgit::git;

sub new
{
  my $class = shift;

  my $self = bless 
               { 
                 history => 'vimgit::history'->new (), 
                 maxfind => 200,
                 @_ 
               }, $class;

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
# findex : seen files index
# sindex : file location index

  my %args = @_;

  my $windex   = $args{windex};
  my $findex   = $args{findex};
  my $sindex   = $args{sindex};
  my $fhlog    = $args{fhlog};
  my $callback = $args{callback};
  my $f = $args{file};

# skip non file elements
  return unless (-f $f);
  return if ($f =~ m/\.vimgit\b/o);

  if ($sindex)
    {
      push @{ $sindex->{&basename ($f)} }, $f;
    }

# fortran & C & C++
  return unless ($f =~ m/\.(f90|f|c|cc)$/io);

  $callback && $callback->($f);

  $fhlog && $fhlog->print ("$f\n");

  my $text;

  if ($windex)
    {
      $text = do { my $fh = 'FileHandle'->new ("<$f"); local $/ = undef; <$fh> };
      &windex_ ($f, $windex, $text);
    }
}

sub idx
{
  my ($self, %args) = @_;

  my $callback = $args{callback};

# create indexes

  my $fhlog = $self->{fhlog};

  my $hashlist = 'vimgit::git'->getHashList ();
  die unless (scalar (@$hashlist));

  my ($hash) = @$hashlist;

  unless ((-f "$self->{TOP}/$hash/windex.db") && (-f "$self->{TOP}/$hash/sindex.db"))
    {
      &mkpath ("$self->{TOP}/$hash");
      my %windex;
      my %findex;
      my %sindex;

      mkdir ($self->{TOP});

      my $follow = 0;
      &File::Find::find ({wanted => sub { &wanted_windex_ (windex => \%windex, findex => \%findex, 
                                                           sindex => \%sindex, fhlog  => $fhlog, 
							   file => $File::Find::name,
                                                           callback => $callback) }, 
                         no_chdir => 1, follow => $follow}, '.');
  
      tie (my %WINDEX,  'DB_File', "$self->{TOP}/$hash/windex.db",  O_RDWR | O_CREAT, 0666, $DB_HASH);
      &cidx (\%windex, \%WINDEX);
      untie (%WINDEX);

      tie (my %SINDEX,  'DB_File', "$self->{TOP}/$hash/sindex.db",  O_RDWR | O_CREAT, 0666, $DB_HASH);
      &cidx (\%sindex, \%SINDEX);
      untie (%SINDEX);

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
