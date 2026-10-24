package Fxtran;

use Fxtran::XPath;
use XML::LibXML;
use List::Util qw (max);
use FileHandle;
use Storable;
use File::Basename;
use Storable;
use Carp qw (croak);
use strict;

use base qw (Exporter);
our @EXPORT = qw (s e F f n t);


sub removeListElement
{

# Remove element from list, take care of removing comma before or after the element

  my $x = shift;

  my $nn = $x->nodeName;

  my ($p) = $x->parentNode;
  
  my @cf = &F ('following-sibling::text()[contains(.,",")]', $x);   
  my @cp = &F ('preceding-sibling::text()[contains(.,",")]', $x);   
  
  if (@cf)
    {   
      $cf[+0]->unbindNode (); 
    }   
  elsif (@cp)
    {   
      $cp[-1]->unbindNode (); 
    }   
  
  $x->parentNode->appendChild (&t (' '));
  my $l = $x->parentNode->lastChild;
  
  $x->unbindNode (); 
  
  while ($l)
    {   
      last if (($l->nodeName ne '#text') && ($l->nodeName ne 'cnt'));
      $l = $l->previousSibling;
      last unless ($l);
      $l->nextSibling->unbindNode;
    }   

  return &F ("./$nn", $p) ? 0 : 1;
}



sub getIndent
{
  my $stmt = shift;

  $stmt or croak;

  my $n = $stmt->previousSibling;

  unless ($n) 
    {    
      if ($stmt->parentNode)
        {
          return &getIndent ($stmt->parentNode);
        }
      return 0;
    }    


  if (($n->nodeName eq '#text') && ($n->data =~ m/\n/o))
    {    
      (my $t = $n->data) =~ s/^.*\n//gsmo;
      return length ($t);
    }    

  if (my $m = $n->lastChild)
    {
      if (($m->nodeName eq '#text') && ($m->data =~ m/\n/o))
        {    
          (my $t = $m->data) =~ s/^.*\n//gsmo;
          return length ($t);
        }    
      return &getIndent ($m);
    }
  elsif (($n->nodeName eq '#text') && ($n->data =~ m/^\s*$/o) && $n->parentNode)
    {
      return length ($n->data) + &getIndent ($n->parentNode);
    }

  return 0;
}

sub reIndent
{
  my ($node, $ns) = @_;

  my $sp = ' ' x $ns; 

  my @cr = &f ('.//text ()[contains (.,"' . "\n" . '")]', $node);

  for my $cr (@cr)
    {    
      (my $t = $cr->data) =~ s/\n/\n$sp/g;
      $cr->setData ($t);
    }
}

sub xpath_by_type
{
  my $type = shift;
  my $size = length ($type);
  return '*[substring(name(),string-length(name())-'.$size.')="-'.$type.'"]';
}

sub _offset
{
  my ($node, $pfound) = @_;

  my $offset = 0;
  for (my $c = $node->previousSibling; $c; $c = $c->previousSibling)
    {
      last if ($c->nodeName eq 'xml-stylesheet');
      my $text = $c->textContent;
      my @text = reverse split (m/(\n)/o, $text);
      for (@text)
        {
          if (m/\n/o)
            {
              $pfound = 1;
              goto FOUND;
            }

          $offset += length ($_);
        }
    }

  if ((! $$pfound) && $node->parentNode)
    {
      $offset += &offset ($node->parentNode, $pfound);
    }

FOUND:

  return $offset;
}

sub offset
{
  my $node = shift;
  return &_offset ($node, \0);
}

# Fold statement workhorse

# Split a statement into tokens; a token is a text node, an element with a single text node,
# or an element which must not be split across lines (literals, variables, arguments, associations)

sub _tokens
{
  my ($node, $tokens) = @_;

  for my $c ($node->childNodes ())
    {
      if ($c->nodeName eq '#text')
        {
          push @$tokens, $c;
          next;
        }

      next unless ($c->nodeType == XML_ELEMENT_NODE);

      my @t = &f ('.//text ()', $c);
      next unless (@t);

      if ((scalar (@t) == 1) || ($c->nodeName =~ m/^(?:literal-E|named-E|associate|arg)$/o))
        {
          push @$tokens, $c;
        }
      else
        {
          &_tokens ($c, $tokens);
        }
    }
}

# A line may be broken before a token, except before blanks, commas and closing parentheses

sub _breakable
{
  my $token = shift;
  return 1 unless ($token->nodeName eq '#text');
  return $token->data !~ m/^\s*(?:[,\)\]]|$)/o;
}

sub _fold
{
  my ($stmt, $indent, $width) = @_;

  my @tok;
  &_tokens ($stmt, \@tok);

# group tokens into units : a breakable token, followed by the tokens which cannot be separated from it
  my @unit;
  for my $i (0 .. $#tok)
    {
      if (($i == 0) || &_breakable ($tok[$i]))
        {
          push @unit, [];
        }
      push @{ $unit[-1] }, $tok[$i];
    }

  my (@cnt, @len);

  my $start = $indent;
  my $len = $indent;

  for my $i (0 .. $#unit)
    {
      my $u = $unit[$i];
      my $w = 0;
      $w += length ($_->textContent) for (@$u);

# room for the trailing " &" unless this is the last unit
      my $need = $w + ($i == $#unit ? 0 : 2);

      if (($len > $start) && ($len + $need > $width))
        {
          my $tok = $u->[0];

          if ($tok->nodeName eq '#text')
            {
              (my $data = $tok->data) =~ s/^\s+//o;
              $w -= length ($tok->data) - length ($data);
              $tok->setData ($data);
            }

          my $p = $tok->parentNode;

# a single blank before the ampersand
          unless ($unit[$i-1][-1]->textContent =~ m/\s$/o)
            {
              $p->insertBefore (&t (' '), $tok);
              $len++;
            }

          my $c = &n ("<cnt>&amp;</cnt>");
          $p->insertBefore ($c, $tok);
          $p->insertBefore (&t ("\n" . (' ' x $indent)), $tok);
          $p->insertBefore (&n ("<cnt>&amp;</cnt>"), $tok);
          $p->insertBefore (&t (' '), $tok);

          push @cnt, $c;
          push @len, $len;

          $start = $len = $indent + 2;
        }

      $len += $w;
    }

  return (\@cnt, \@len);
}


sub expand
{
  my $stmt = shift;

  for (&f ('.//f:cnt', $stmt), &f ('.//f:C', $stmt), &f ('.//f:L', $stmt))
    {
      $_->unbindNode ();
    }
# merge text nodes first, so that all blanks around former line breaks are collapsed
  $stmt->normalize ();
  for (&f ('.//text ()', $stmt))
    {
      my $data = $_->data;
      if ($data =~ m/\n/o)
        {
          $data =~ s/\s+/ /go;
          $_->setData ($data);
        }
    }

  $stmt->normalize ();
}

# Fold a statement

sub fold
{
  my ($stmt, %opts) = @_;

# align => 0 : put ampersands at the end of lines, separated by a single blank, instead of aligning them
# width       : maximum line length (default 100)
  my $align = exists ($opts{align}) ? $opts{align} : 1;

  &expand ($stmt);

  my $indent = &offset ($stmt);

  my ($cnt, $len) = &_fold ($stmt, $indent, $opts{width} || 100);

  if ($align)
    {
      my ($lenmax) = sort { $b <=> $a } @$len;
      for my $i (0 .. $#$cnt)
        {
          $cnt->[$i]->parentNode->insertBefore (&t (' ' x ($lenmax - $len->[$i])), $cnt->[$i]);
        }
    }

  $stmt->normalize ();
}

sub t
{
  'XML::LibXML::Text'->new ($_[0]);
}

sub s
{
  &Fxtran::fxtran (statement => $_[0]);
}

sub e
{
  &Fxtran::fxtran (expr => $_[0]);
}

# Returns the statement the element belongs to

sub stmt
{
  my $e = shift;
  my @anc = reverse &f ('./ancestor::*', $e);
  my ($stmt) = grep { $_->nodeName =~ m/-stmt$/o } @anc;
  return $stmt;
}

sub expr
{
  my $e = shift;
  my @anc = reverse &f ('./ancestor::*', $e);
  my ($expr) = grep { $_->nodeName =~ m/-E$/o } @anc;
  return $expr;
}

sub F
{
  my $xpath = &Fxtran::XPath::preprocess (shift (@_));
  return &f ($xpath, @_);
}

sub f
{
  my $xpc = 'XML::LibXML::XPathContext'->new ();
  $xpc->registerNs (f => 'http://fxtran.net/#syntax');

  my $xpath = shift (@_);

  while (@_ && ($xpath =~ s/\?/$_[0]/))
    {
      shift (@_);
    }

  ref ($_[0]) or &croak ("Expected node");

  my @x;

  eval 
    {
      @x = $xpc->findnodes ($xpath, $_[0]);
    };

  if (my $c = $@)
    {
      &croak ($c);
    }

  if (! defined ($_[1]))
    {
    }
  elsif ($_[1] == 1)
    {
      @x = map { $_->textContent } @x;
      for (@x)
        {
          s/\s+//go;
          $_ = uc ($_);
        }
    }
  elsif ($_[1] == 2)
    {
      @x = map { $_->textContent } @x;
    }
  return @x;
}

sub n
{
  my $xml = shift;
  my $doc = 'XML::LibXML'->load_xml (string => '<?xml version="1.0"?><object xmlns="http://fxtran.net/#syntax">' . $xml . '</object>');

  my @childs = $doc->documentElement ()->childNodes ();
  if (@childs > 1)
    {
      return @childs;
    }
  else
    {
      return $childs[0];
    }
}

sub TRUE
{
  &n ('<literal-E>.TRUE.</literal-E>');
}

sub FALSE
{
  &n ('<literal-E>.FALSE.</literal-E>');
}

sub fxtran
{
  use fxtran;

  my %args = @_;

  my @fopts = @{ $args{fopts} || [] };
  my @xopts = @{ $args{xopts} || [] };

  if ($args{string})
    {
      use File::Temp;
      my $fh = 'File::Temp'->new (SUFFIX => '.F90');
      $fh->print ($args{string});
      $fh->flush ();
      system (qw (fxtran -construct-tag -no-include), @fopts, $fh->filename)
        && die ($args{string});
      my $doc = 'XML::LibXML'->load_xml (location => $fh->filename . '.xml', @xopts);
      return $doc;
    }
  elsif ($args{fragment})
    {
      chomp (my $fragment = $args{fragment});
      my $program = << "EOF";
$fragment
END
EOF
      my $xml = &fxtran::run ('-construct-tag', '-no-include', @fopts, $program);
      my $doc = 'XML::LibXML'->load_xml (string => $xml, @xopts);
      $doc = $doc->lastChild->firstChild;

      $doc->lastChild->unbindNode () for (1 .. 2);
      my @c = $doc->childNodes ();

      return @c;
    }
  elsif ($args{statement})
    {
      my $program = << "EOF";
$args{statement}
END 
EOF
      my $xml = &fxtran::run ('-line-length', 300, $program);
      my $doc = 'XML::LibXML'->load_xml (string => $xml, @xopts);
      my $n = $doc->documentElement->firstChild->firstChild;
      return $n;
    }
  elsif ($args{expr})
    {
      my $program = << "EOF";
X = $args{expr}
END
EOF
      my $xml = &fxtran::run ('-line-length', 300, $program);
      my $doc = 'XML::LibXML'->load_xml (string => $xml, @xopts);
      my $n = $doc->documentElement->firstChild->firstChild->lastChild->firstChild;
      return $n;
    }
  elsif (my $f = $args{location})
    {
      use File::stat;
      return unless (-f $f);

      my $dir = $args{dir} || &dirname ($f);
      my $xml = "$dir/" . &basename ($f) . '.xml';

      my @cmd = (qw (fxtran -construct-tag -no-include), @fopts, -o => $xml, $f);
      system (@cmd)
        && croak ("`@cmd' failed\n");

      my $doc = 'XML::LibXML'->load_xml (location => $xml, @xopts);
      return $doc;
    }
  croak "@_";
}

1;
