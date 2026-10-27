package vimgit::config;

# configuration : ~/.vimgit/config, then the .vimgit/config of the workspace; both are Perl,
# run in package vimgit::config::dsl, one function per setting :
#
#   repo      qw (ial-source fiat);           # workspace only
#   exclude   fiat => 'tests/**', ...;        # in HOME, for the repositories mounted as fiat
#   index     qw (*.F90 *.h);                 # lists : -name removes, - empties
#   blacklist qw (DR_HOOK MPL_*);
#   git '/bin/git'; vim 'vim'; jobs 4; results 200; gitgrep 200; context 2; keep 3; depth 5;
#   key       definition => '²', '`';         # the keys of an action
#
# files of the old format (keyword words ..., one per line) are read too. Each setting
# keeps the file and line it comes from.

use strict;

use FileHandle;

# single values and their defaults

our %DEFAULT = (git => '/bin/git', vim => 'vim', jobs => 4, results => 200, gitgrep => 200,
                context => 2, keep => 3, depth => undef);

our @VALUES = qw (git vim jobs results gitgrep context keep depth);

# actions and their default keys

our @ACTIONS = qw (search search_window definition definition_window back);

our %KEYS = (search => [ '<TAB>' ], search_window => [ '<S-TAB>' ], definition => [ '²', '`', 'œ' ],
             definition_window => [ '<C-²>' ], back => [ '<BS>' ]);

# the configuration being read, for the functions of vimgit::config::dsl

our $CURRENT;

sub home
{
  my $home = $ENV{HOME} || (getpwuid ($>))[7];
  return "$home/.vimgit/config";
}

sub new
{
  my $class = shift;
  return bless { value => {}, repo => [], exclude => [], index => undef, blacklist => [],
                 key => {}, removed => [], warnings => [], old => [] }, $class;
}

sub load
{

# the configuration of workspace $args{root} : ~/.vimgit/config, then $root/.vimgit/config;
# without root, ~/.vimgit/config only

  my ($class, %args) = @_;

  my $self = $class->new ();

  $self->readfile ($class->home (), scope => 'home') if (-f $class->home ());
  $self->readfile ("$args{root}/.vimgit/config", scope => 'workspace') if ($args{root} && (-f "$args{root}/.vimgit/config"));

  return $self;
}

sub warning
{
  my ($self, $msg) = @_;
  push @{ $self->{warnings} }, $msg;
}

sub isold_
{

# true if $text is in the old format : keyword words ..., no ; ( ) or quotes

  my $text = shift;
  my @l = grep { m/\S/o } map { (my $l = $_) =~ s/#.*//o; $l } split (m/\n/o, $text);
  return @l && ! grep { ! m/^\s*(?:repo|exclude|index|blacklist)\s+[^;()'"]*$/o } @l;
}

sub readfile
{

# read file $file; scope : home or workspace

  my ($self, $file, %args) = @_;

  my $text = do { my $fh = 'FileHandle'->new ("<$file") or die ("Cannot read $file\n"); local $/ = undef; <$fh> };

  local $CURRENT = $self;
  local $self->{scope} = $args{scope};
  local $self->{file} = $file;

# origins are shown as ~/.vimgit/config:N, .vimgit/config:N

  local $self->{label} = ($args{scope} eq 'home') ? '~/.vimgit/config' : '.vimgit/config';

  if (&isold_ ($text))
    {
      push @{ $self->{old} }, $self->{label};
      my $n = 0;
      for my $line (split (m/\n/o, $text))
        {
          $n++;
          $line =~ s/#.*//o;
          next unless ($line =~ m/\S/o);
          my ($key, @args) = split (' ', $line);
          local $self->{origin} = "$self->{label}:$n";
          if (($key eq 'exclude') && (@args == 2))
            {
              &vimgit::config::dsl::exclude (@args);
            }
          elsif (($key ne 'exclude') && @args && (grep { $_ eq $key } qw (repo index blacklist)))
            {
              no strict 'refs';
              &{"vimgit::config::dsl::$key"} (@args);
            }
          else
            {
              $self->warning ("$self->{label}:$n: cannot understand `$line'");
            }
        }
      return;
    }

# warnings of Perl : with the error, or as warnings of vimgit

  my @w;
  my $ok = do
    {
      local $SIG{__WARN__} = sub { push @w, $_[0] };
      local $SIG{__DIE__};
      eval "package vimgit::config::dsl;\n#line 1 \"$file\"\n$text\n;1";
    };
  die ("vimgit: error in $file:\n" . join ('', @w) . $@) unless ($ok);
  $self->warning ($_) for (map { s/\s+$//or } @w);
}

sub origin_
{

# file:line of the setting being recorded : the line of the configuration file calling the
# function, or the line of an old format file

  my $self = shift;
  return $self->{origin} if ($self->{origin});
  for (my $i = 1; ; $i++)
    {
      my @c = caller ($i) or last;
      return "$self->{label}:$c[2]" if ($c[1] eq $self->{file});
    }
  return $self->{label};
}

sub list_
{

# add items @items to list $name; -name removes, - empties

  my ($self, $name, @items) = @_;

  my $origin = $self->origin_ ();
  my $list = $self->{$name} ||= [];
  my $same = ($name eq 'blacklist') ? sub { lc ($_[0]) eq lc ($_[1]) } : sub { $_[0] eq $_[1] };

  for my $item (@items)
    {
      if ($item eq '-')
        {
          push @{ $self->{removed} }, map { [ $name, $_->[0], $origin ] } @$list;
          @$list = ();
        }
      elsif ($item =~ m/^-(.+)$/o)
        {
          my $x = $1;
          push @{ $self->{removed} }, map { [ $name, $_->[0], $origin ] } grep { $same->($_->[0], $x) } @$list;
          @$list = grep { ! $same->($_->[0], $x) } @$list;
        }
      else
        {
          push @$list, [ $item, $origin ];
        }
    }
}

# accessors

sub value
{
  my ($self, $name) = @_;
  return exists ($self->{value}{$name}) ? $self->{value}{$name}[0] : $DEFAULT{$name};
}

sub repos
{
  my $self = shift;
  return map { $_->[0] } @{ $self->{repo} };
}

sub excludes
{

# exclude patterns of the repository mounted as $mount; home : only those from HOME

  my ($self, $mount) = @_;
  return map { $_->[1] } grep { $_->[0] eq $mount } @{ $self->{exclude} };
}

sub indexed
{

# globs of the files to index; empty : the default list

  my $self = shift;
  return $self->{index} ? (map { $_->[0] } @{ $self->{index} }) : ();
}

sub blacklist
{
  my $self = shift;
  return map { $_->[0] } @{ $self->{blacklist} };
}

sub keysof
{

# the keys of action $action

  my ($self, $action) = @_;
  return @{ $self->{key}{$action} ? $self->{key}{$action}[0] : $KEYS{$action} };
}

sub text
{

# the configuration in the format of the files, each setting followed by its origin

  my $self = shift;

  my $q = sub { my $s = shift; return 'undef' unless (defined ($s)); $s =~ s/(['\\])/\\$1/go; "'$s'" };

  my @l;
  my $line = sub
  {
    my ($text, $origin) = @_;
    push @l, sprintf ("%-60s # %s", $text, $origin);
  };

  $line->("repo $_->[0];", $_->[1]) for (map { [ $q->($_->[0]), $_->[1] ] } @{ $self->{repo} });
  $line->("exclude $_->[0] => " . $q->($_->[1]) . ';', $_->[2]) for (@{ $self->{exclude} });
  if ($self->{index})
    {
      $line->("index " . $q->($_->[0]) . ';', $_->[1]) for (@{ $self->{index} });
    }
  else
    {
      $line->("index qw (" . join (' ', 'vimgit::lang'->defaultindexed ()) . ');', 'default');
    }
  $line->("blacklist " . $q->($_->[0]) . ';', $_->[1]) for (@{ $self->{blacklist} });
  for my $name (@VALUES)
    {
      my ($v, $origin) = exists ($self->{value}{$name}) ? @{ $self->{value}{$name} } : ($DEFAULT{$name}, 'default');
      $line->(sprintf ("%-9s %s;", $name, ((defined ($v) && ($v =~ m/^\d+$/o)) ? $v : $q->($v))), $origin);
    }
  for my $action (@ACTIONS)
    {
      my $origin = $self->{key}{$action} ? $self->{key}{$action}[1] : 'default';
      $line->("key $action => " . join (', ', map { $q->($_) } $self->keysof ($action)) . ';', $origin);
    }
  $line->("# removed : $_->[0] " . $q->($_->[1]), $_->[2]) for (@{ $self->{removed} });

  return join ('', map { "$_\n" } @l);
}

package vimgit::config::dsl;

# the functions of the configuration files; index is a Perl builtin, overridden here

use strict;
use subs qw (index);

sub current_
{
  return $vimgit::config::CURRENT || die ("vimgit::config: no configuration being read\n");
}

sub repo
{
  my $c = &current_ ();
  if ($c->{scope} eq 'home')
    {
      $c->warning ($c->origin_ () . ": repo is for the .vimgit/config of a workspace; ignored");
      return;
    }
  push @{ $c->{repo} }, map { [ $_, $c->origin_ () ] } @_;
}

sub exclude
{

# exclude repo => pattern, ...; a pattern -x removes x, - all the patterns of the repository

  my $c = &current_ ();
  my $origin = $c->origin_ ();
  my @a = @_;
  while (my ($mount, $pattern) = splice (@a, 0, 2))
    {
      if (! defined ($pattern))
        {
          $c->warning ("$origin: exclude $mount: no pattern");
        }
      elsif ($pattern =~ m/^-(.*)$/o)
        {
          my $x = $1;
          my $gone = sub { ($_[0][0] eq $mount) && (($x eq '') || ($_[0][1] eq $x)) };
          push @{ $c->{removed} }, map { [ "exclude $mount =>", $_->[1], $origin ] } grep { $gone->($_) } @{ $c->{exclude} };
          $c->{exclude} = [ grep { ! $gone->($_) } @{ $c->{exclude} } ];
        }
      else
        {
          push @{ $c->{exclude} }, [ $mount, $pattern, $origin, $c->{scope} ];
        }
    }
}

sub index
{
  my $c = &current_ ();
  $c->{index} ||= [];
  $c->list_ ('index', @_);
}

sub blacklist
{
  my $c = &current_ ();
  $c->list_ ('blacklist', @_);
}

sub key
{
  my $c = &current_ ();
  my ($action, @keys) = @_;
  unless (grep { $_ eq $action } @vimgit::config::ACTIONS)
    {
      $c->warning ($c->origin_ () . ": key $action: unknown action (@vimgit::config::ACTIONS)");
      return;
    }
  $c->{key}{$action} = [ \@keys, $c->origin_ () ];
}

for my $name (@vimgit::config::VALUES)
  {
    no strict 'refs';
    *{"vimgit::config::dsl::$name"} = sub
    {
      my $c = &current_ ();
      unless (@_ == 1)
        {
          $c->warning ($c->origin_ () . ": $name takes one value");
          return;
        }
      $c->{value}{$name} = [ $_[0], $c->origin_ () ];
    };
  }

1;
