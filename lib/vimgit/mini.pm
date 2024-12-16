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

  my %args = @_;

  $args{TOP}  = [split (m/\s+/o, $args{TOP} )];
  $args{EXCL} = [split (m/\s+/o, $args{EXCL})];

  my $self = bless 
               { 
                 history => 'vimgit::history'->new (), 
                 maxfind => 200,
                 %args,
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

  my $windex = $args{windex};
  my $findex = $args{findex};
  my $sindex = $args{sindex};
  my $fhlog  = $args{fhlog};
  my $top    = $args{top};
  my $file   = $args{file};
  my $excl   = $args{excl};

# skip non file elements
  return unless (-f $file);
  return if ($file =~ m/\.vimgit\b/o);

  for my $excl (@$excl)
    {
      return if (index ($file, $excl) == 0);
    }

  $file =~ s,^\./,,o;

  if ($sindex)
    {
      push @{ $sindex->{&basename ($file)} }, 'File::Spec'->abs2rel ($file, $top);
    }

# fortran & C & C++
  return unless ($file =~ m/\.(f90|f|c|cc)$/io);

  $fhlog && $fhlog->print ("$file\n");

  my $text;

  if ($windex)
    {
      $text = do { my $fh = 'FileHandle'->new ("<$file"); local $/ = undef; <$fh> };
      &windex_ ($file, $windex, $text);
    }
}

sub idx
{
  my ($self, %args) = @_;


  for my $TOP (@{ $self->{TOP} })
    {
# create indexes

      my $fhlog = $self->{fhlog};
     
      my $hashlist = 'vimgit::git'->getHashList (repo => $TOP);
      die unless (scalar (@$hashlist));
     
      my ($hash) = @$hashlist;
     
      unless ((-f "$TOP/.vimgit/$hash/windex.db") && (-f "$TOP/.vimgit/$hash/sindex.db"))
        {
          &mkpath ("$TOP/.vimgit/$hash");
          my %windex;
          my %findex;
          my %sindex;
     
          my $follow = 0;
          &File::Find::find ({wanted => sub { &wanted_windex_ (windex => \%windex, findex => \%findex, 
                                                               sindex => \%sindex, fhlog  => $fhlog, 
                                                               top => $TOP, excl => $self->{EXCL},
            						       file => $File::Find::name); },
                             no_chdir => 1, follow => $follow}, $TOP);
      
          tie (my %WINDEX,  'DB_File', "$TOP/.vimgit/$hash/windex.db",  O_RDWR | O_CREAT, 0666, $DB_HASH);
          &cidx (\%windex, \%WINDEX);
          untie (%WINDEX);
     
          tie (my %SINDEX,  'DB_File', "$TOP/.vimgit/$hash/sindex.db",  O_RDWR | O_CREAT, 0666, $DB_HASH);
          &cidx (\%sindex, \%SINDEX);
          untie (%SINDEX);
     
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
