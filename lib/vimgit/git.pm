package vimgit::git;

use strict;
use Data::Dumper;

my $GIT = '/bin/git';

sub getHashList
{
  my $class = shift;
  my @hash = split (m/\n/o, `$GIT --no-pager log --pretty=%H -10`);
  return \@hash;
}

sub getTopDirectory
{
  my $class = shift;
  chomp (my $top = `$GIT rev-parse --show-toplevel`);
  return $top;
}

sub getStatus
{
  my $class = shift;
  my @m = map { chomp; split (m/\s+/o) } split (m/\n/o, `$GIT status --porcelain=v1`);
  print &Dumper (\@m);
  die;
}

sub getDiff
{
  my ($class, %args) = @_;

  my %m;

# no renames : a single path per entry; -z : status and path separated by NUL

  my @m = split (m/\0/o, `$GIT diff --name-status --no-renames -z $args{hash}`);

  while (my ($m, $f) = splice (@m, 0, 2))
    {
      if ($m eq 'D')
        {
          $m{$f} = '-';
        }
      elsif ($m eq 'A')
        {
          $m{$f} = '+';
        }
      else
        {
# M, T (type change), U (unmerged), etc. : scan the working tree file
          $m{$f} = 'M';
        }
    }

  for (split (m/\n/o, `$GIT ls-files --others --exclude-standard`))
    {
      chomp;
      $m{$_} = '+';
    }

  return \%m;
}

1;
