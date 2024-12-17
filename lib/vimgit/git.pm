package vimgit::git;
use Data::Dumper;
use Capture::Tiny qw (capture);

sub runGitCommand
{
  my $cmd = shift;
  my $out = `$cmd`;
  return $out;
}

sub getHashList
{
  my $class = shift;
  my %args = @_;
  my $repo = $args{repo};
  my @hash = split (m/\n/o, &runGitCommand ("git -C $repo --no-pager log --pretty=%H -10"));
  return \@hash;
}

sub getTopDirectory
{
  my $class = shift;
  my %args = @_;
  my $repo = $args{repo};
  chomp (my $top = &runGitCommand ("git -C $repo rev-parse --show-toplevel"));
  return $top;
}

sub getStatus
{
  my $class = shift;
  my @m = map { chomp; split (m/\s+/o) } split (m/\n/o, &runGitCommand ("git status --porcelain=v1"));
  print &Dumper (\@m);
  die;
}

sub getDiff
{
  my ($class, %args) = @_;

  my $repo = $args{repo};

  my %m;

  for (split (m/\n/o, &runGitCommand ("git -C $repo diff --name-status $args{hash}")))
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

  for (split (m/\n/o, &runGitCommand ("git -C $repo ls-files --others --exclude-standard")))
    {
      chomp;
      $m{$_} = '+';
    }

  return \%m;
}

1;
