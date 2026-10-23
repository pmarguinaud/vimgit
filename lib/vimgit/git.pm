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

  for (split (m/\n/o, `$GIT diff --name-status $args{hash}`))
    {
      chomp;
      my ($m, $f, $g) = split (m/\s+/o);
      if ($m eq 'M')
        {
          $m{$f} = 'M';
        }
      elsif ($m eq 'A')
        {
          $m{$f} = '+';
        }
      elsif ($m eq 'D')
        {
          $m{$f} = '-';
        }
      elsif ($m =~ m/^R/o)
        {
          $m{$f} = '-';
	  $m{$g} = '+';
	}
      else
        {
          die $_;
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
