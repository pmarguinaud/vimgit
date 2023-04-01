package vimgit::git;

use strict;
use Data::Dumper;

sub getHashList
{
  my $class = shift;
  my @hash = split (m/\n/o, `git --no-pager log --pretty=%H -10`);
  return \@hash;
}

sub getTopDirectory
{
  my $class = shift;
  chomp (my $top = `git rev-parse --show-toplevel`);
  return $top;
}

sub getStatus
{
  my $class = shift;
  my @m = map { chomp; split (m/\s+/o) } split (m/\n/o, `git status --porcelain=v1`);
  print &Dumper (\@m);
  die;
}

sub getDiff
{
  my ($class, %args) = @_;

  my %m;

  for (split (m/\n/o, `git diff --name-status $args{hash}`))
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

  for (split (m/\n/o, `git ls-files --others --exclude-standard`))
    {
      chomp;
      $m{$_} = '+';
    }

  return \%m;
}

1;
