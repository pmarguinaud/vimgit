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

# definitions start a statement (not a comment, not END SUBROUTINE); prefixes allowed

      my $routine = qr/^\s*(?:(?:pure|impure|elemental|recursive|non_recursive|module)\s+)*(?:subroutine|interface)\s+$word\b/i;

      if ($linea =~ m/\bcall\s*$/io)
        {

# search for subroutine definition

          return $edtr->definition (word => $word, regex => $routine);

        }
      elsif ($linea =~ m/%\s*$/io)
        {

          return $edtr->find (word => $word, regex => qr/%\s*$word\b/i, hist => 1, lang => 'fortran');

        }
      elsif ($linea =~ m/\buse\s*$/io)
        {

# search for module definition

          return $edtr->find (word => $word, defn => 1, regex => qr/^\s*module\s+$word\b/i, hist => 1, lang => 'fortran');

        }
      elsif (($linea =~ m/#include\s*"$/o) && ($lineb =~ m/^(?:\.intfb)?\.h"\s*$/o))
        {

# search for routine definition

          return $edtr->definition (word => $word, regex => $routine);

        }
      elsif (($linea =~ m/^\s*(?:type|class)\s*\(\s*$/io) && ($lineb =~ m/^\s*\)/io))
        {

# search for type definition : TYPE X, TYPE :: X, TYPE, EXTENDS(Y), ... :: X

          return $edtr->definition (word => $word, types => 1, regex => qr/^\s*type\b(?:\s*,[^:]*::|\s*::)?\s*$word\b/i);

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

sub strip_
{

# remove the comment of a statement, blank the contents of character strings

  my $l = shift;

  return $l unless ($l =~ m/['"!]/o);

  $l =~ s{('[^']*'?|"[^"]*"?)|!.*}{ defined ($1) ? substr ($1, 0, 1) . (' ' x (length ($1) - 1)) : '' }ge;

  return $l;
}

sub units
{

# program units defined in Fortran source $text (fixed : fixed form) and the routines each one
# calls (CALL statements; type-bound calls as written, x%y); returns
# [ { name, line, internal, calls => [ name, ... ] }, ... ] for programs, subroutines and
# functions outside interface blocks; internal : contained in a program, a subroutine or a
# function. Calls in a function contained in a subroutine or a program go to that subroutine
# or program.
#
# types : an array receiving the derived types defined in $text :
# { name, line, internal, extends => [ name, line ], components => [ { kind (type, class),
# type, name, line, attr (pointer, allocatable, or empty) }, ... ] }; components of
# intrinsic types and bound procedures are left out

  my ($class, $text, %args) = @_;

  my $types = $args{types} || [];

  my $prefix = qr/(?:(?:pure|impure|elemental|recursive|non_recursive|module)\s+)*/i;
  my $type = qr/(?:(?:integer|real|logical|complex|character|double\s*precision|type|class)\s*(?:\((?:[^()]|\([^()]*\))*\))?\s*(?:\*\s*\d+\s*)?)/i;

  my (@unit, @stack, $iface, $tdef, $cont);
  my $n = 0;

  for my $line (split (m/\n/o, $text))
    {
      $n++;

# only lines with a keyword of interest, all lines in a type definition
      next unless ($tdef || ($line =~ m/call|subroutine|function|program|module|end|interface|block/io)
                         || ($line =~ m/^\s*type\s*[,:\w]/io));
      next if ($line =~ m/^\s*#/o);

      if ($args{fixed})
        {
          next if ($line =~ m/^[cC*!dD]/o);
          $line = $line =~ s/^\t//o ? $line : (length ($line) > 6 ? substr ($line, 6) : '');
        }

# in a type definition, statements continued with & are joined

      if ($tdef)
        {
          my $l = &strip_ ($line);
          $l =~ s/^\s*&//o if ($cont);
          if ($l =~ s/&\s*$//o)
            {
              $cont = [ $cont ? ($cont->[0] . $l, $cont->[1]) : ($l, $n) ];
              next;
            }
          my $at = $n;
          ($l, $at) = ($cont->[0] . $l, $cont->[1]) if ($cont);
          undef $cont;
          for my $s (split (m/;/o, $l))
            {
              &tdefline_ ($tdef, $s, $at) or undef $tdef;
            }
          next;
        }

      for my $s (split (m/;/o, &strip_ ($line)))
        {
          $s =~ s/^\s*&//o;
          $s =~ s/^\s*\d+\s+//o;

          if ($s =~ m/^\s*(?:abstract\s+)?interface\b/io)
            {
              $iface++;
              next;
            }
          if ($s =~ m/^\s*end\s*interface\b/io)
            {
              $iface-- if ($iface);
              next;
            }
          next if ($iface);

# type definition : TYPE X, TYPE :: X, TYPE, attributes :: X; not TYPE (X), TYPE IS (X)

          if (($s =~ m/^\s*type\s*(?:,\s*(.*?))?\s*::\s*(\w+)\s*$/io) || ($s =~ m/^\s*type\s+(?!is\b)()(\w+)\s*$/io))
            {
              my ($attr, $name) = ($1, lc ($2));
              $tdef = { name => $name, line => $n, components => [],
                        internal => scalar (grep { $_->{name} } @stack) };
              $tdef->{extends} = [ lc ($1), $n ] if ($attr && ($attr =~ m/\bextends\s*\(\s*(\w+)\s*\)/io));
              push @$types, $tdef;
              next;
            }

          if (($s =~ m/^\s*$prefix(subroutine|function)\s+(\w+)/i) || ($s =~ m/^\s*$prefix$type\s*$prefix(function)\s+(\w+)/i)
           || ($s =~ m/^\s*(program)\s+(\w+)/io))
            {
              my $u = { kind => lc ($1), name => lc ($2), line => $n, calls => [],
                        internal => scalar (grep { $_->{name} } @stack) };
              push @unit, $u;
              push @stack, $u;
              next;
            }
          if ($s =~ m/^\s*(?:sub)?module\s+(?!(?:procedure|subroutine|function)\b)\w+/io)
            {
              push @stack, { kind => 'module' };
              next;
            }
          if ($s =~ m/^\s*block\s*data\b/io)
            {
              push @stack, { kind => 'block data' };
              next;
            }
          if ($s =~ m/^\s*end\s*(?:(?:program|module|submodule|subroutine|function|block\s*data)\b.*)?$/io)
            {
              pop @stack;
              next;
            }

          while ($s =~ m/(?:^|\))\s*call\s+(\w+(?:\s*\([^()]*\))?(?:\s*%\s*\w+(?:\s*\([^()]*\))?)*)/gio)
            {
              (my $c = lc ($1)) =~ s/\([^()]*\)|\s+//go;

# the unit receiving the call : the innermost subroutine or program, or a function alone

              my ($u) = grep { ($_->{kind} eq 'subroutine') || ($_->{kind} eq 'program') } reverse (@stack);
              ($u) = grep { $_->{kind} eq 'function' } reverse (@stack) unless ($u);
              push @{ $u->{calls} }, $c if ($u);
            }
        }
    }

  return \@unit;
}

sub tdefline_
{

# statement $s (line $n) of type definition $t; returns false at END TYPE

  my ($t, $s, $n) = @_;

  return 0 if ($s =~ m/^\s*end\s*type\b/io);

  if ($s =~ m/^\s*contains\b/io)
    {
      $t->{bound} = 1;
      return 1;
    }

  return 1 if ($t->{bound});

  my ($kind, $type, $rest) = ($s =~ m/^\s*(type|class)\s*\(\s*(\w+)\s*\)(.*)$/io) or return 1;

  my ($attr, $names) = ($rest =~ m/^(.*?)::(.*)$/o) ? ($1, $2) : ('', $rest);

  $attr = ($attr =~ m/\bpointer\b/io) ? 'pointer' : ($attr =~ m/\ballocatable\b/io) ? 'allocatable' : '';

# names : without array specifications and initial values

  1 while ($names =~ s/\([^()]*\)|\[[^\[\]]*\]//go);
  for (split (m/,/o, $names))
    {
      next unless (m/^\s*(\w+)/o);
      push @{ $t->{components} }, { kind => lc ($kind), type => lc ($type), name => lc ($1), line => $n, attr => $attr };
    }

  return 1;
}


1;
