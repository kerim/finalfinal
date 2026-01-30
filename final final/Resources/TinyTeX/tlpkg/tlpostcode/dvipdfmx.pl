# $Id: dvipdfmx.pl 69127 2023-12-14 21:41:41Z karl $
# post action for dvipdfmx to handle upgrades of map files
# Copyright 2011-2023 Norbert Preining
# This file is licensed under the GNU General Public License version 2
# or any later version.

my $texdir;
my $mode;

BEGIN {
  $^W = 1;
  $mode = lc($ARGV[0]);
  $texdir = $ARGV[1];
  # make Perl find our packages first:
  unshift (@INC, "$texdir/tlpkg");
}
use TeXLive::TLUtils qw(wndws mkdirhier conv_to_w32_path log info);

if ($mode eq 'install') {
  do_install();
} elsif ($mode eq 'remove') {
  do_remove();
} else {
  die("unknown mode: $mode\n");
}

sub do_remove {
  # do nothing
}

sub do_install {
  # bin-installs font-config related stuff
  chomp( my $tmfsysconf = `kpsewhich -var-value=TEXMFSYSCONFIG` ) ;
  chomp( my $tmfmain = `kpsewhich -var-value=TEXMFMAIN` ) ;
  if (-r "$tmfsysconf/dvipdfmx/dvipdfmx.cfg") {
    # assume that succeeds, we tested -r above!
    open (FOO, "<$tmfsysconf/dvipdfmx/dvipdfmx.cfg");
    my @lines = <FOO>;
    chomp(@lines);
    close(FOO);
    my @outlines;
    my $isold = 0;
    for my $l (@lines) {
      if ($l =~ m/^D.*-dDELAYSAFER/) {
        $isold = 1;
        push @outlines, "D  \"rungs -q -dALLOWPSTRANSPARENCY -dSAFER -dNOPAUSE -dBATCH -dEPSCrop -sPAPERSIZE=a0 -sDEVICE=pdfwrite -dCompatibilityLevel=%v -dAutoFilterGrayImages=false -dGrayImageFilter=/FlateEncode -dAutoFilterColorImages=false -dColorImageFilter=/FlateEncode -dAutoRotatePages=/None -sOutputFile='%o' '%i' -c quit\"
%% If you change the above invocation, also change dvipdfmx-unsafe.cfg!\n\n";
      } else {
        push @outlines, "$l\n";
      }
    }
    if ($isold) {
      print "dvipdfmx postinstall: updating $tmfsysconf/dvipdfmx/dvipdfmx.cfg rungs command to remove -dDELAYSAFER\n";
      if (!open (FOO, ">$tmfsysconf/dvipdfmx/dvipdfmx.cfg")) {
        fprintf STDERR "dvipdfmx.pl(postcode): Cannot write $tmfsysconf/dvipdfmx/dvipdfmx.cfg
  This config file contains dangerous configuration of gs.
  Please see $tmfmain/dvipdfmx/dvipdfmx.cfg for changes
";
        return 0;
      }
      print FOO @outlines;
      close (FOO);
    }
  }
  return 0;
}

### Local Variables:
### perl-indent-level: 2
### tab-width: 2
### indent-tabs-mode: nil
### End:
# vim:set tabstop=2 expandtab: #
