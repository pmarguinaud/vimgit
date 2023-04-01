package vimgit::lang::fortran;

use strict;
use base qw (vimgit::lang);

use Data::Dumper;

sub do_find
{
  my ($class, %args) = @_;

  my $word = $args{word};
  my $line = $args{line};
  my $i1   = $args{i1};
  my $i2   = $args{i2};
  my $edtr = $args{editor};
  my $defn = $args{defn};
  my $call = $args{call};

  $word = lc ($word);

  my $linea = substr ($line, 0, $i1);
  my $lineb = substr ($line, $i2+1);


#edtr->{fhlog}->print (&Dumper ([$linea, $lineb, $word]));

  if ($defn)
    {

      if ($linea =~ m/\bcall\s*$/io)
        {

# search for subroutine definition

          return $edtr->find (word => $word, defn => 1, regex => qr/(?:subroutine|interface)\s*$word\b/i, hist => 1, lang => 'fortran');

        }
      elsif ($linea =~ m/%\s*$/io)
        {

          return $edtr->find (word => $word, regex => qr/%\s*$word\b/i, hist => 1, lang => 'fortran');

        }
      elsif ($linea =~ m/\buse\s*$/io)
        {

# search for module definition

          return $edtr->find (word => $word, defn => 1, regex => qr/module\s*$word\b/i, hist => 1, lang => 'fortran');

        }
      elsif (($linea =~ m/#include\s*"$/o) && ($lineb =~ m/^(?:\.intfb)?\.h"\s*$/o))
        {

# search for routine definition

          return $edtr->find (word => $word, defn => 1, regex => qr/(?:subroutine|interface)\s*$word\b/i, hist => 1, lang => 'fortran');

        }
      elsif (($linea =~ m/^\s*type\s*\(\s*$/io) && ($lineb =~ m/^\s*\)/io))
        {
      
# search for type definition

          return $edtr->find (word => $word, defn => 1, regex => qr/(?:type)\s*$word\b/i, hist => 1, lang => 'fortran');

        }

    }
  elsif ($call)
    {
      return $edtr->find (word => $word, call => 1, hist => 1, lang => 'fortran');
    }
  else
    {
      return 'vimgit::lang'->do_find (%args);
    }

}


1;
