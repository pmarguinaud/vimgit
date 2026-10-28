package vimgit::fxparse;

# Fortran files parsed by fxtran, for :AT : program units and their dummy arguments,
# declarations, USE statements, ASSOCIATE selectors, CALL statements and their actual
# arguments, statements with their lines. A file is parsed once per session while its date
# does not change. Elements of interest carry their line and column (attributes vL, vC,
# 0-based column).

use strict;

use File::Temp;
use XML::LibXML;

my $NS = 'http://fxtran.net/#syntax';

my %CACHE; # path -> parsed file

# the fxtran binary, for fixed form files (the fxtran setting, set by the editor)

our $FXTRAN;

sub available
{

# true if the fxtran Perl module can be loaded; the error otherwise

  my $class = shift;
  return 1 if (eval { require fxtran; 1 });
  return (0, $@);
}

sub parse
{

# parsed file $path (a path to open); dies if fxtran fails

  my ($class, $path) = @_;

  my $mtime = (stat ($path))[9];
  die ("Cannot read $path\n") unless (defined ($mtime));

  my $c = $CACHE{$path};
  return $c if ($c && ($c->{mtime} == $mtime));

  my $text = do { open (my $fh, '<', $path) or die ("Cannot read $path\n"); local $/ = undef; <$fh> };

  require fxtran;

# preprocessor macros (__FILENAME__, __LINE__) are not Fortran : strings of the same length,
# so that columns do not change; an empty file crashes the fxtran module

  (my $code = $text) =~ s{\b(__\w+?__)\b}{"'" . ('x' x (length ($1) - 2)) . "'"}ge;

  my $xml;
  if ($code !~ m/\S/o)
    {
      $xml = qq(<?xml version="1.0"?><object xmlns="$NS"><file name="empty"></file></object>);
    }
  elsif ($path =~ m/\.f(?:or|77)?$/io)
    {
# fixed form : fxtran knows it from the name of the file
      my $dir = 'File::Temp'->newdir ();
      (my $b = $path) =~ s,.*/,,;
      my $f = "$dir/$b";
      open (my $fh, '>', $f) or die ("Cannot write $f\n");
      print $fh $code;
      close ($fh);
      system ($FXTRAN || 'fxtran', '-construct-tag', '-no-include', -o => "$f.xml", $f) == 0
        or die ("fxtran failed on $path\n");
      $xml = do { open (my $fx, '<', "$f.xml") or die ("Cannot read $f.xml\n"); local $/ = undef; <$fx> };
    }
  else
    {
      $xml = &fxtran::run ('-construct-tag', '-no-include', '-line-length', 512, $code);
    }

  my $doc = 'XML::LibXML'->load_xml (string => $xml, huge => 1);
  my $xpc = 'XML::LibXML::XPathContext'->new ($doc);
  $xpc->registerNs (f => $NS);

  my $self = $CACHE{$path} = bless { path => $path, mtime => $mtime, doc => $doc, xpc => $xpc,
                                     lines => [ split (m/\n/o, $text, -1) ] }, $class;

  $self->positions_ ();
  $self->units_ ();
  $self->statements_ ();

  return $self;
}

sub positions_
{

# line and column of each element : the text of the XML is the source

  my $self = shift;

  my ($line, $col) = (1, 0);

  my $walk;
  $walk = sub
  {
    no warnings 'recursion';
    my $n = shift;
    for (my $c = $n->firstChild; $c; $c = $c->nextSibling)
      {
        if ($c->nodeType == XML_ELEMENT_NODE)
          {
            $c->setAttribute (vL => $line);
            $c->setAttribute (vC => $col);
            $walk->($c);
          }
        elsif (($c->nodeType == XML_TEXT_NODE) || ($c->nodeType == XML_CDATA_SECTION_NODE))
          {
            my $t = $c->data;
            my $nl = ($t =~ tr/\n//);
            if ($nl)
              {
                $line += $nl;
                $col = length ($t) - rindex ($t, "\n") - 1;
              }
            else
              {
                $col += length ($t);
              }
          }
      }
  };

  my ($file) = $self->{xpc}->findnodes ('//f:file');
  $walk->($file || $self->{doc}->documentElement);
}

sub text_
{

# source text of element $n, without the vL vC attributes

  my $n = shift;
  return $n->textContent;
}

sub units_
{

# program units : { node, kind (subroutine, function, program, module), name, line, end,
# dummies => [ name ], host (unit containing it, for subroutines and functions contained
# in a routine or a program), module (module containing it) }

  my $self = shift;

  my $xpc = $self->{xpc};
  my @u;
  my %of;

  for my $pu ($xpc->findnodes ('//f:program-unit'))
    {
      my ($stmt) = $xpc->findnodes ('./*[1]', $pu);
      next unless ($stmt);
      my ($kind) = ($stmt->nodeName =~ m/^(subroutine|function|program|module|submodule|block-data)-stmt$/o);
      next unless ($kind);
      my ($n) = $xpc->findnodes ('.//f:N/f:n', $stmt);
      my @d = map { uc ($_->textContent) } $xpc->findnodes ('./f:dummy-arg-LT/f:arg-N/f:N/f:n', $stmt);
      my ($end) = $xpc->findnodes ('./*[last()]', $pu);
      my $u = { node => $pu, kind => $kind, name => ($n ? uc ($n->textContent) : ''), line => $stmt->getAttribute ('vL'),
                end => ($end ? $end->getAttribute ('vL') + ($end->textContent =~ tr/\n//) : $stmt->getAttribute ('vL')),
                dummies => \@d };
      $of{$pu->unique_key} = $u;
      push @u, $u;
    }

  for my $u (@u)
    {
      for (my $p = $u->{node}->parentNode; $p && ($p->nodeType == XML_ELEMENT_NODE); $p = $p->parentNode)
        {
          my $h = $of{$p->unique_key} or next;
          if ($h->{kind} eq 'module')
            {
              $u->{module} ||= $h;
            }
          elsif (($u->{kind} eq 'subroutine') || ($u->{kind} eq 'function'))
            {
              $u->{host} ||= $h;
            }
        }
    }

  $self->{units} = \@u;
  $self->{unitof} = \%of;
}

sub statements_
{

# statements outside other statements, in order : [ node, first line, last line ]

  my $self = shift;

  my @s;
  my $walk;
  $walk = sub
  {
    no warnings 'recursion';
    my $n = shift;
    for my $c ($n->childNodes)
      {
        next unless ($c->nodeType == XML_ELEMENT_NODE);
        if ($c->nodeName =~ m/-stmt$/o)
          {
            my $l = $c->getAttribute ('vL');
            push @s, [ $c, $l, $l + ($c->textContent =~ tr/\n//) ];
          }
        else
          {
            $walk->($c);
          }
      }
  };

  my ($file) = $self->{xpc}->findnodes ('//f:file');
  $walk->($file);

  $self->{stmts} = \@s;
  $self->{stmtidx} = { map { ($s[$_][0]->unique_key, $_) } (0 .. $#s) };
}

sub unit_at
{

# innermost unit holding line $line (subroutine, function, program)

  my ($self, $line) = @_;
  my ($u) = sort { $b->{line} <=> $a->{line} }
            grep { ($_->{kind} =~ m/^(?:subroutine|function|program)$/o) && ($_->{line} <= $line) && ($line <= $_->{end}) }
            @{ $self->{units} };
  return $u;
}

sub unit_of
{

# unit holding node $n

  my ($self, $n) = @_;
  for (my $p = $n->parentNode; $p && ($p->nodeType == XML_ELEMENT_NODE); $p = $p->parentNode)
    {
      my $u = $self->{unitof}{$p->unique_key};
      return $u if ($u);
    }
  return undef;
}

sub declaration
{

# declaration of $name in unit $u (not in units contained in it) : { stmt, en (the name in
# the declaration), attrs => { INTENT, POINTER, OPTIONAL, ALLOCATABLE ... } }; undef if none

  my ($self, $u, $name) = @_;

  my $xpc = $self->{xpc};
  for my $s ($xpc->findnodes ('./f:T-decl-stmt', $u->{node}))
    {
      for my $en ($xpc->findnodes ('.//f:EN-decl/f:EN-N/f:N/f:n', $s))
        {
          next unless (uc ($en->textContent) eq $name);
          my %attr = map { (uc ($_->textContent), 1) } $xpc->findnodes ('.//f:attribute-N', $s);
          return { stmt => $s, en => $en, attrs => \%attr };
        }
    }

  return undef;
}

sub uses
{

# USE statements of unit $u : [ { stmt, module, only => { local name => node } or undef } ]

  my ($self, $u) = @_;

  my $xpc = $self->{xpc};
  my @r;
  for my $s ($xpc->findnodes ('./f:use-stmt', $u->{node}))
    {
      my ($m) = $xpc->findnodes ('./f:module-N/f:N/f:n', $s);
      my $only;
      if ($s->textContent =~ m/\bonly\s*:/io)
        {
          $only = {};
          for my $r ($xpc->findnodes ('.//f:rename', $s))
            {
              my ($l) = $xpc->findnodes ('./f:use-N/f:N/f:n', $r);
              ($l) = $xpc->findnodes ('.//f:n', $r) unless ($l);
              $only->{uc ($l->textContent)} = $l if ($l);
            }
        }
      push @r, { stmt => $s, module => ($m ? uc ($m->textContent) : '?'), only => $only };
    }

  return \@r;
}

sub calls
{

# CALL statements of routine $name in unit $u and the units contained in it (not type-bound
# calls) : [ call-stmt node ]

  my ($self, $u, $name) = @_;

  my $xpc = $self->{xpc};
  return [ grep { my ($n) = $xpc->findnodes ('./f:procedure-designator/f:named-E', $_);
                  $n && ! $xpc->findnodes ('./f:R-LT', $n)
                     && (uc (($xpc->findnodes ('./f:N/f:n', $n))[0]->textContent) eq $name) }
           $xpc->findnodes ('.//f:call-stmt', $u->{node}) ];
}

sub calls_all
{

# CALL statements in unit $u and the units contained in it (not type-bound calls)

  my ($self, $u) = @_;
  my $xpc = $self->{xpc};
  return [ grep { my ($n) = $xpc->findnodes ('./f:procedure-designator/f:named-E', $_); $n && ! $xpc->findnodes ('./f:R-LT', $n) }
           $xpc->findnodes ('.//f:call-stmt', $u->{node}) ];
}

sub args
{

# actual arguments of call-stmt $call : ( [ arg node, expression node, keyword or undef,
# position among positional arguments or undef ] )

  my ($self, $call) = @_;

  my $xpc = $self->{xpc};
  my ($i, @r) = (0);
  for my $a ($xpc->findnodes ('./f:arg-spec/f:arg', $call))
    {
      my ($k) = $xpc->findnodes ('./f:arg-N', $a);
      my ($e) = grep { ($_->nodeType == XML_ELEMENT_NODE) && ($_->nodeName ne 'arg-N') } $a->childNodes;
      push @r, [ $a, $e, ($k ? uc ($k->getAttribute ('n')) : undef), ($k ? undef : $i++) ];
    }
  return @r;
}

sub actual
{

# actual argument of call-stmt $call for dummy argument number $pos (0-based), named $name :
# the argument passed with that keyword, or at that position; ( arg node, expression node )

  my ($self, $call, $pos, $name) = @_;

  my $xpc = $self->{xpc};
  my @a = $xpc->findnodes ('./f:arg-spec/f:arg', $call);

  for my $a (@a)
    {
      my ($k) = $xpc->findnodes ('./f:arg-N', $a);
      next unless ($k && (uc ($k->getAttribute ('n')) eq $name));
      my ($e) = grep { ($_->nodeType == XML_ELEMENT_NODE) && ($_->nodeName ne 'arg-N') } $a->childNodes;
      return ($a, $e);
    }

  my @p = grep { ! $xpc->findnodes ('./f:arg-N', $_) } @a;
  return () unless (defined ($pos) && ($pos < @p));
  my ($e) = grep { $_->nodeType == XML_ELEMENT_NODE } $p[$pos]->childNodes;
  return ($p[$pos], $e);
}

sub associates
{

# ASSOCIATE names around node $n, innermost first : [ { name, selector node, association node } ]

  my ($self, $n) = @_;

# once per node, and once per ASSOCIATE construct

  my $key = $n->unique_key;
  return $self->{assocof}{$key} if ($self->{assocof}{$key});

  my $xpc = $self->{xpc};
  my @r;
  for (my $p = $n->parentNode; $p && ($p->nodeType == XML_ELEMENT_NODE); $p = $p->parentNode)
    {
      last if ($p->nodeName eq 'program-unit');
      next unless ($p->nodeName eq 'associate-construct');
      my $c = $self->{assocon}{$p->unique_key} ||= [
        map { my ($an) = $xpc->findnodes ('./f:associate-N/f:n', $_);
              my ($sel) = $xpc->findnodes ('./f:selector/*', $_);
              ($an && $sel) ? ({ name => uc ($an->textContent), selector => $sel, node => $_ }) : () }
        $xpc->findnodes ('./f:associate-stmt/f:associate-LT/f:associate', $p) ];
      push @r, @$c;
    }

  return $self->{assocof}{$key} = \@r;
}

sub expression
{

# what expression node $e is : { kind => name (base, R-LT text, component : true if the
# references hold a %), literal, expression ; text }

  my ($self, $e) = @_;

  my $xpc = $self->{xpc};
  my $text = $e->textContent;

  return { kind => 'literal', text => $text } if ($e->nodeName =~ m/^(?:literal|string)-E$/o);

  if ($e->nodeName eq 'named-E')
    {
      my ($n) = $xpc->findnodes ('./f:N/f:n', $e);
      my ($r) = $xpc->findnodes ('./f:R-LT', $e);
      return { kind => 'name', text => $text, base => uc ($n->textContent), refs => ($r ? $r->textContent : ''),
               component => ($r && $xpc->findnodes ('./f:component-R', $r)) ? 1 : 0 };
    }

  return { kind => 'expression', text => $text };
}

sub path
{

# path of expression node $e : [ base, component, ... ] (upper case, subscripts left out);
# undef if it is not a variable or a component

  my ($self, $e) = @_;

  return undef unless ($e && ($e->nodeName eq 'named-E'));

  my $xpc = $self->{xpc};
  my ($n) = $xpc->findnodes ('./f:N/f:n', $e);
  return [ uc ($n->textContent), map { uc ($_->textContent) } $xpc->findnodes ('./f:R-LT/f:component-R/f:ct', $e) ];
}

sub unit_named
{

# unit $name contained in the same routine as unit $u (or in $u itself)

  my ($self, $u, $name) = @_;
  my $top = $u;
  $top = $top->{host} while ($top->{host});
  for my $c (@{ $self->{units} })
    {
      next unless (($c->{name} eq $name) && $c->{host});
      my $t = $c;
      $t = $t->{host} while ($t->{host});
      return $c if ($t == $top);
    }
  return undef;
}

sub declares
{

# true if unit $u has $name as a dummy argument or declares it

  my ($self, $u, $name) = @_;
  return 1 if (grep { $_ eq $name } @{ $u->{dummies} });
  return $self->declaration ($u, $name) ? 1 : 0;
}

sub context
{

# lines of the statement holding node $n, with $k statements before and after it :
# ( [ [ line number, text ] ], ... ) with undef between lines that do not follow each other

  my ($self, $n, $k) = @_;

  my $s = $n;
  my $i;
  while ($s)
    {
      $i = $self->{stmtidx}{$s->unique_key};
      last if (defined ($i));
      $s = $s->parentNode;
    }
  return () unless (defined ($i));

  my $st = $self->{stmts};
  my ($lo, $hi) = ($i - $k, $i + $k);
  $lo = 0 if ($lo < 0);
  $hi = $#$st if ($hi > $#$st);

  my (@l, %seen, $prev);
  for my $j ($lo .. $hi)
    {
      for my $l ($st->[$j][1] .. $st->[$j][2])
        {
          next if ($seen{$l}++);
          push @l, undef if (defined ($prev) && ($l > $prev + 1));
          push @l, [ $l, $self->{lines}[$l - 1] ];
          $prev = $l;
        }
    }

  return @l;
}

1;
