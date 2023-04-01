package vimgit::tools;

use strict;

sub slurp
{

# read file in a single shot

  my $t = do { local $/ = undef; my $fh = 'FileHandle'->new ("<$_[0]"); $fh ? <$fh> : '' };
  return $t;
}

sub fcmp
{
  my ($f1, $f2) = @_;
  return &slurp ($f1) cmp &slurp ($f2);
}

sub copy
{

# copy a file and log

  my (%args) = @_;
  my $fhlog = $args{fhlog};
  
  use File::Copy qw ();
  use File::Path qw ();
  $fhlog && $fhlog->print ("Copy $args{fi} $args{fo}\n");
  &File::Path::mkpath (&File::Basename::dirname ($args{fo}));
  &File::Copy::copy ($args{fi}, $args{fo});
}

sub findword
{
  my ($col, $line) = @_;

  my $i1 = $col;
  my $i2 = $col;
  
  for (; $i1 >=0; $i1--)
    {
      if (substr ($line, $i1, 1) !~ m/\w/io)
        {
          $i1++;
          last;
        }
    }
  
  $i1 = 0
    if ($i1 < 0);
  
  for (; $i2 < length ($line); $i2++)
    {
      if (substr ($line, $i2, 1) !~ m/\w/io)
        {
          $i2--;
          last;
        }
    }
  
  $i2 = length ($line)-1
    if ($i2 > length ($line));
  
  my $word = $i1 < $i2 ? substr ($line, $i1, $i2-$i1+1) : undef;
  
  return ($word, $i1, $i2);
}

sub bt
{
  my @bt;
  for (my $i = 0; my @c = caller ($i); $i++)
    {
      push @bt, "$c[1]:$c[2]";
    }
  return \@bt;
}


1;

