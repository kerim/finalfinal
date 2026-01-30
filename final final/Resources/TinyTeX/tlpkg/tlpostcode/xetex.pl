# $Id: xetex.pl 70088 2024-02-23 16:44:23Z karl $
# post action for xetex to handle system font stuff.
# Copyright 2008-2024 Norbert Preining
# This file is licensed under the GNU General Public License version 2
# or any later version.
#
# We create the fontconfig configuration file with all TL fonts.  On Windows,
# we also run fc-cache to make the fonts available.
# https://tug.org/texlive/doc/texlive-en/texlive-en.html#xetexfontconfig

my $texdir;
my $mode;
my $skip_gen; # not used for (un)install

BEGIN {
  $^W = 1;
  $mode = lc(@ARGV ? $ARGV[0] : "no-argv0??");
  $texdir = $ARGV[1] || "no-argv1??";
  $skip_gen = (defined $ARGV[2]) ? 1 : 0; # not used with normal installs
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
  # fontconfig-related stuff.
  # use these TL-specific variables, supported by TL's XeTeX on Windows,
  # so we don't touch a true system directory such as /etc/fonts on Unix,
  # as we would do if we used FC_CACHEDIR and FONTCONFIG_PATH.
  chomp( my $fcachedir = `kpsewhich -var-value=XE_FC_CACHEDIR` ) ;
  chomp( my $fconfdir = `kpsewhich -var-value=XE_FONTCONFIG_PATH` ) ;
  chomp( my $fconffile = `kpsewhich -var-value=FONTCONFIG_FILE` ) ;
  if (-r "$texdir/bin/windows/xetex.exe") {
    # Windows binaries are installed, so copy the tlpostcode/xetex/*
    # subdirs into the TL dirs above.
    # 
    # We (weirdly) create the directories and then remove them to ensure
    # that any intervening subdirs are created, but the actual dir we
    # copy into is non-existent.
    mkdirhier($fcachedir);
    mkdirhier($fconfdir);
    TeXLive::TLUtils::rmtree($fcachedir);
    TeXLive::TLUtils::rmtree($fconfdir);
    
    my @cpycmd = ();
    if (wndws()) {
      push @cpycmd, "xcopy", "/e", "/i", "/q", "/y";
    } else {
      push @cpycmd, "cp", "-R";
    }
    
    # copy trees from install area.
    my $postxetex = "$texdir/tlpkg/tlpostcode/xetex";
    system(@cpycmd,
         (wndws() ? conv_to_w32_path("$postxetex/conf") : "$postxetex/conf"),
         (wndws() ? conv_to_w32_path($fconfdir) : $fconfdir));
    system(@cpycmd,
         (wndws() ? conv_to_w32_path("$postxetex/cache") : "$postxetex/cache"),
         (wndws() ? conv_to_w32_path($fcachedir) : $fcachedir));
 
    if (open(FONTSCONF, "<$postxetex/conf/fonts.conf")) {
      my @lines = <FONTSCONF>;
      close(FONTSCONF);
      if (open(FONTSCONF, ">$fconfdir/$fconffile")) {
        my $winfontdir;
        if (wndws()) {
          $winfontdir = $ENV{'SystemRoot'}.'/fonts';
          $winfontdir =~ s!\\!/!g;
        }
        foreach (@lines) {
          $_ =~ s!c:/Program Files/texlive/YYYY!$texdir!;
          $_ =~ s!c:/windows/fonts!$winfontdir! if wndws();
          print FONTSCONF;
        }
        close(FONTSCONF)
        || tlwarn("close($postxetex/conf/fonts.conf) failed: $!");
      } else {
        tlwarn("open(>$fconfdir/$fconffile) failed: $!");
      }
    } else {
      tlwarn("open($postxetex/conf/fonts.conf) failed: $!");
    }
  }

  if (wndws()) {
    if (!$skip_gen) {
      # call fc-cache -- but only if we're actually running under Windows,
      # not merely installing its binaries.
      info("Running fc-cache -v -r\n");
      log( `fc-cache -v -r 2>&1` );  # run it, log output
    }

  } else {
    # non-Windows: merely create a texlive-fontconfig.conf file,
    # in (the TL directory) XE_FONTCONFIG_PATH.
    mkdirhier("$fconfdir");
    if (!open(FONTSCONF, ">$fconfdir/texlive-fontconfig.conf")) {
      tlwarn("open(>$fconfdir/texlive-fontconfig.conf) failed: $!");
    } else {
      print FONTSCONF '<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
';
      for my $t (qw/opentype truetype type1/) {
        print FONTSCONF "  <dir>$texdir/texmf-dist/fonts/$t</dir>\n";
      }
      print FONTSCONF "</fontconfig>\n";
      close(FONTSCONF)
      || tlwarn("close($fconfdir/texlive-fontconfig.conf) failed: $!");
    }

    # cygwin-specific warning
    # we don't have our platform name available ...
    chomp(my $un = `uname`);
    if ($un =~ m/cygwin/i) {
      if (! -r "/usr/bin/cygfontconfig-1.dll") {
        print STDERR <<CYGWIN_XETEX;

XeTeX on Cygwin requires fontconfig.
Please run cygwin's setup program and install the fontconfig package.

CYGWIN_XETEX
      }
    }
  }
}

### Local Variables:
### perl-indent-level: 2
### tab-width: 2
### indent-tabs-mode: nil
### End:
# vim:set tabstop=2 expandtab: #
