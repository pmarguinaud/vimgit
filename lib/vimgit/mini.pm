package vimgit;

use strict;
use DB_File;
use FileHandle;
use Fcntl qw (O_RDWR O_CREAT);
use File::Basename;
use Data::Dumper;
use File::Path;

use vimgit::history;
use vimgit::git;
use vimgit::lang;

sub new
{
  my $class = shift;

  my $self = bless 
               { 
                 history => 'vimgit::history'->new (), 
                 maxfind => 200,
                 @_ 
               }, $class;

# REPO : top of the git repository; indexes are kept in its .git directory

  $self->{IDX} ||= 'vimgit::git'->getGitDirectory (top => $self->{REPO}) . '/vimgit'
    if ($self->{REPO});

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

  $f =~ s,^\./,,o;

  if ($sindex)
    {
      push @{ $sindex->{&basename ($f)} }, $f;
    }

# fortran & C & C++
  my $ext = 'vimgit::lang'->indexed ();
  return unless ($f =~ m/$ext$/);

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

  my $hashlist = 'vimgit::git'->getHashList (top => $self->{REPO});
  die ("No commit in $self->{REPO}") unless (scalar (@$hashlist));

  my ($hash) = @$hashlist;

  my $dir = "$self->{IDX}/$hash";

  unless ((-f "$dir/windex.db") && (-f "$dir/sindex.db"))
    {
      &mkpath ($dir);
      my %windex;
      my %sindex;

# files listed by git, relative to the top of the repository (the current directory)

      for my $f (@{ 'vimgit::git'->getFiles (top => $self->{REPO}) })
        {
          &wanted_windex_ (windex => \%windex, sindex => \%sindex, fhlog  => $fhlog, 
                           file => $f, callback => $callback);
        }
  
      tie (my %WINDEX,  'DB_File', "$dir/windex.db",  O_RDWR | O_CREAT, 0666, $DB_HASH);
      &cidx (\%windex, \%WINDEX);
      untie (%WINDEX);

      tie (my %SINDEX,  'DB_File', "$dir/sindex.db",  O_RDWR | O_CREAT, 0666, $DB_HASH);
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
