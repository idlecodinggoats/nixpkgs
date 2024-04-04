{ config, lib, options, pkgs, ... }:

with lib;

let

  plymouth = pkgs.plymouth.override {
    systemd = config.boot.initrd.systemd.package;
  };

  cfg = config.boot.plymouth;
  opt = options.boot.plymouth;

  nixosBreezePlymouth = pkgs.plasma5Packages.breeze-plymouth.override {
    logoFile = cfg.logo;
    logoName = "nixos";
    osName = "NixOS";
    osVersion = config.system.nixos.release;
  };

  plymouthLogos = pkgs.runCommand "plymouth-logos" { inherit (cfg) logo; } ''
    mkdir -p $out

    # For themes that are compiled with PLYMOUTH_LOGO_FILE
    mkdir -p $out/etc/plymouth
    ln -s $logo $out/etc/plymouth/logo.png

    # Logo for bgrt theme
    # Note this is technically an abuse of watermark for the bgrt theme
    # See: https://gitlab.freedesktop.org/plymouth/plymouth/-/issues/95#note_813768
    mkdir -p $out/share/plymouth/themes/spinner
    ln -s $logo $out/share/plymouth/themes/spinner/watermark.png

    # Logo for spinfinity theme
    # See: https://gitlab.freedesktop.org/plymouth/plymouth/-/issues/106
    mkdir -p $out/share/plymouth/themes/spinfinity
    ln -s $logo $out/share/plymouth/themes/spinfinity/header-image.png
  '';

  themesEnv = pkgs.buildEnv {
    name = "plymouth-themes";
    paths = [
      plymouth
      plymouthLogos
    ] ++ cfg.themePackages;
  };

  configFile = pkgs.writeText "plymouthd.conf" ''
    [Daemon]
    ShowDelay=0
    DeviceTimeout=8
    Theme=${cfg.theme}
    ${cfg.extraConfig}
  '';

in

{

  options = {

    boot.plymouth = {

      enable = mkEnableOption (lib.mdDoc "Plymouth boot splash screen");

      font = mkOption {
        default = "${pkgs.dejavu_fonts.minimal}/share/fonts/truetype/DejaVuSans.ttf";
        defaultText = literalExpression ''"''${pkgs.dejavu_fonts.minimal}/share/fonts/truetype/DejaVuSans.ttf"'';
        type = types.path;
        description = lib.mdDoc ''
          Font file made available for displaying text on the splash screen.
        '';
      };

      themePackages = mkOption {
        default = lib.optional (cfg.theme == "breeze") nixosBreezePlymouth;
        defaultText = literalMD ''
          A NixOS branded variant of the breeze theme when
          `config.${opt.theme} == "breeze"`, otherwise
          `[ ]`.
        '';
        type = types.listOf types.package;
        description = lib.mdDoc ''
          Extra theme packages for plymouth.
        '';
      };

      theme = mkOption {
        default = "bgrt";
        type = types.str;
        description = lib.mdDoc ''
          Splash screen theme.
        '';
      };

      logo = mkOption {
        type = types.path;
        # Dimensions are 48x48 to match GDM logo
        default = "${pkgs.nixos-icons}/share/icons/hicolor/48x48/apps/nix-snowflake-white.png";
        defaultText = literalExpression ''"''${pkgs.nixos-icons}/share/icons/hicolor/48x48/apps/nix-snowflake-white.png"'';
        example = literalExpression ''
          pkgs.fetchurl {
            url = "https://nixos.org/logo/nixos-hires.png";
            sha256 = "1ivzgd7iz0i06y36p8m5w48fd8pjqwxhdaavc0pxs7w1g7mcy5si";
          }
        '';
        description = lib.mdDoc ''
          Logo which is displayed on the splash screen.
          Currently supports PNG file format only.
        '';
      };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = lib.mdDoc ''
          Literal string to append to `configFile`
          and the config file generated by the plymouth module.
        '';
      };

    };

  };

  config = mkIf cfg.enable {

    boot.kernelParams = [ "splash" ];

    # To be discoverable by systemd.
    environment.systemPackages = [ plymouth ];

    environment.etc."plymouth/plymouthd.conf".source = configFile;
    environment.etc."plymouth/plymouthd.defaults".source = "${plymouth}/share/plymouth/plymouthd.defaults";
    environment.etc."plymouth/logo.png".source = cfg.logo;
    environment.etc."plymouth/themes".source = "${themesEnv}/share/plymouth/themes";
    # XXX: Needed because we supply a different set of plugins in initrd.
    environment.etc."plymouth/plugins".source = "${plymouth}/lib/plymouth";

    systemd.tmpfiles.rules = [
      "d /run/plymouth 0755 root root 0 -"
      "L+ /run/plymouth/plymouthd.defaults - - - - /etc/plymouth/plymouthd.defaults"
      "L+ /run/plymouth/themes - - - - /etc/plymouth/themes"
      "L+ /run/plymouth/plugins - - - - /etc/plymouth/plugins"
    ];

    systemd.packages = [ plymouth ];

    systemd.services.plymouth-kexec.wantedBy = [ "kexec.target" ];
    systemd.services.plymouth-halt.wantedBy = [ "halt.target" ];
    systemd.services.plymouth-quit-wait.wantedBy = [ "multi-user.target" ];
    systemd.services.plymouth-quit.wantedBy = [ "multi-user.target" ];
    systemd.services.plymouth-poweroff.wantedBy = [ "poweroff.target" ];
    systemd.services.plymouth-reboot.wantedBy = [ "reboot.target" ];
    systemd.services.plymouth-read-write.wantedBy = [ "sysinit.target" ];
    systemd.services.systemd-ask-password-plymouth.wantedBy = [ "multi-user.target" ];
    systemd.paths.systemd-ask-password-plymouth.wantedBy = [ "multi-user.target" ];

    # Prevent Plymouth taking over the screen during system updates.
    systemd.services.plymouth-start.restartIfChanged = false;

    boot.initrd.systemd = {
      extraBin.plymouth = "${plymouth}/bin/plymouth"; # for the recovery shell
      storePaths = [
        "${lib.getBin config.boot.initrd.systemd.package}/bin/systemd-tty-ask-password-agent"
        "${plymouth}/bin/plymouthd"
        "${plymouth}/sbin/plymouthd"
      ];
      packages = [ plymouth ]; # systemd units
      contents = {
        # Files
        "/etc/plymouth/plymouthd.conf".source = configFile;
        "/etc/plymouth/logo.png".source = cfg.logo;
        "/etc/plymouth/plymouthd.defaults".source = "${plymouth}/share/plymouth/plymouthd.defaults";
        # Directories
        "/etc/plymouth/plugins".source = pkgs.runCommand "plymouth-initrd-plugins" {} ''
          # Check if the actual requested theme is here
          if [[ ! -d ${themesEnv}/share/plymouth/themes/${cfg.theme} ]]; then
              echo "The requested theme: ${cfg.theme} is not provided by any of the packages in boot.plymouth.themePackages"
              exit 1
          fi

          moduleName="$(sed -n 's,ModuleName *= *,,p' ${themesEnv}/share/plymouth/themes/${cfg.theme}/${cfg.theme}.plymouth)"

          mkdir -p $out/renderers
          # module might come from a theme
          cp ${themesEnv}/lib/plymouth/*.so $out
          cp ${plymouth}/lib/plymouth/renderers/*.so $out/renderers
          # useless in the initrd, and adds several megabytes to the closure
          rm $out/renderers/x11.so
        '';
        "/etc/plymouth/themes".source = pkgs.runCommand "plymouth-initrd-themes" {} ''
          # Check if the actual requested theme is here
          if [[ ! -d ${themesEnv}/share/plymouth/themes/${cfg.theme} ]]; then
              echo "The requested theme: ${cfg.theme} is not provided by any of the packages in boot.plymouth.themePackages"
              exit 1
          fi

          mkdir -p $out/${cfg.theme}
          cp -r ${themesEnv}/share/plymouth/themes/${cfg.theme}/* $out/${cfg.theme}
          # Copy more themes if the theme depends on others
          for theme in $(grep -hRo '/share/plymouth/themes/.*$' $out | xargs -n1 basename); do
              if [[ -d "${themesEnv}/share/plymouth/themes/$theme" ]]; then
                  if [[ ! -d "$out/$theme" ]]; then
                    echo "Adding dependent theme: $theme"
                    mkdir -p "$out/$theme"
                    cp -r "${themesEnv}/share/plymouth/themes/$theme"/* "$out/$theme"
                  fi
              else
                echo "Missing theme dependency: $theme"
              fi
          done
          # Fixup references
          for theme in $out/*/*.plymouth; do
            sed -i "s,${builtins.storeDir}/.*/share/plymouth/themes,$out," "$theme"
          done
        '';

        # Fonts
        "/etc/plymouth/fonts".source = pkgs.runCommand "plymouth-initrd-fonts" {} ''
          mkdir -p $out
          cp ${cfg.font} $out
        '';
        "/etc/fonts/fonts.conf".text = ''
          <?xml version="1.0"?>
          <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
          <fontconfig>
              <dir>/etc/plymouth/fonts</dir>
          </fontconfig>
        '';
      };
      # Properly enable units. These are the units that arch copies
      services = {
        plymouth-halt.wantedBy = [ "halt.target" ];
        plymouth-kexec.wantedBy = [ "kexec.target" ];
        plymouth-poweroff.wantedBy = [ "poweroff.target" ];
        plymouth-quit-wait.wantedBy = [ "multi-user.target" ];
        plymouth-quit.wantedBy = [ "multi-user.target" ];
        plymouth-read-write.wantedBy = [ "sysinit.target" ];
        plymouth-reboot.wantedBy = [ "reboot.target" ];
        plymouth-start.wantedBy = [ "initrd-switch-root.target" "sysinit.target" ];
        plymouth-switch-root-initramfs.wantedBy = [ "halt.target" "kexec.target" "plymouth-switch-root-initramfs.service" "poweroff.target" "reboot.target" ];
        plymouth-switch-root.wantedBy = [ "initrd-switch-root.target" ];
      };
      # Link in runtime files before starting
      services.plymouth-start.preStart = ''
        mkdir -p /run/plymouth
        ln -sf /etc/plymouth/{plymouthd.defaults,themes,plugins} /run/plymouth/
      '';
    };

    # Insert required udev rules. We take stage 2 systemd because the udev
    # rules are only generated when building with logind.
    boot.initrd.services.udev.packages = [ (pkgs.runCommand "initrd-plymouth-udev-rules" {} ''
      mkdir -p $out/etc/udev/rules.d
      cp ${config.systemd.package.out}/lib/udev/rules.d/{70-uaccess,71-seat}.rules $out/etc/udev/rules.d
      sed -i '/loginctl/d' $out/etc/udev/rules.d/71-seat.rules
    '') ];

    boot.initrd.extraUtilsCommands = lib.mkIf (!config.boot.initrd.systemd.enable) ''
      copy_bin_and_libs ${plymouth}/bin/plymouth
      copy_bin_and_libs ${plymouth}/bin/plymouthd

      # Check if the actual requested theme is here
      if [[ ! -d ${themesEnv}/share/plymouth/themes/${cfg.theme} ]]; then
          echo "The requested theme: ${cfg.theme} is not provided by any of the packages in boot.plymouth.themePackages"
          exit 1
      fi

      moduleName="$(sed -n 's,ModuleName *= *,,p' ${themesEnv}/share/plymouth/themes/${cfg.theme}/${cfg.theme}.plymouth)"

      mkdir -p $out/lib/plymouth/renderers
      # module might come from a theme
      cp ${themesEnv}/lib/plymouth/*.so $out/lib/plymouth
      cp ${plymouth}/lib/plymouth/renderers/*.so $out/lib/plymouth/renderers
      # useless in the initrd, and adds several megabytes to the closure
      rm $out/lib/plymouth/renderers/x11.so

      mkdir -p $out/share/plymouth/themes
      cp ${plymouth}/share/plymouth/plymouthd.defaults $out/share/plymouth

      # Copy themes into working directory for patching
      mkdir themes

      # Use -L to copy the directories proper, not the symlinks to them.
      # Copy all themes because they're not large assets, and bgrt depends on the ImageDir of
      # the spinner theme.
      cp -r -L ${themesEnv}/share/plymouth/themes/* themes

      # Patch out any attempted references to the theme or plymouth's themes directory
      chmod -R +w themes
      find themes -type f | while read file
      do
        sed -i "s,${builtins.storeDir}/.*/share/plymouth/themes,$out/share/plymouth/themes,g" $file
      done

      # Install themes
      cp -r themes/* $out/share/plymouth/themes

      # Install logo
      mkdir -p $out/etc/plymouth
      cp -r -L ${themesEnv}/etc/plymouth $out/etc

      # Setup font
      mkdir -p $out/share/fonts
      cp ${cfg.font} $out/share/fonts
      mkdir -p $out/etc/fonts
      cat > $out/etc/fonts/fonts.conf <<EOF
      <?xml version="1.0"?>
      <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
      <fontconfig>
          <dir>$out/share/fonts</dir>
      </fontconfig>
      EOF
    '';

    boot.initrd.extraUtilsCommandsTest = mkIf (!config.boot.initrd.systemd.enable) ''
      $out/bin/plymouthd --help >/dev/null
      $out/bin/plymouth --help >/dev/null
    '';

    boot.initrd.extraUdevRulesCommands = mkIf (!config.boot.initrd.systemd.enable) ''
      cp ${config.systemd.package}/lib/udev/rules.d/{70-uaccess,71-seat}.rules $out
      sed -i '/loginctl/d' $out/71-seat.rules
    '';

    # We use `mkAfter` to ensure that LUKS password prompt would be shown earlier than the splash screen.
    boot.initrd.preLVMCommands = mkIf (!config.boot.initrd.systemd.enable) (mkAfter ''
      mkdir -p /etc/plymouth
      mkdir -p /run/plymouth
      ln -s $extraUtils/etc/plymouth/logo.png /etc/plymouth/logo.png
      ln -s ${configFile} /etc/plymouth/plymouthd.conf
      ln -s $extraUtils/share/plymouth/plymouthd.defaults /run/plymouth/plymouthd.defaults
      ln -s $extraUtils/share/plymouth/themes /run/plymouth/themes
      ln -s $extraUtils/lib/plymouth /run/plymouth/plugins
      ln -s $extraUtils/etc/fonts /etc/fonts

      plymouthd --mode=boot --pid-file=/run/plymouth/pid --attach-to-session
      plymouth show-splash
    '');

    boot.initrd.postMountCommands = mkIf (!config.boot.initrd.systemd.enable) ''
      plymouth update-root-fs --new-root-dir="$targetRoot"
    '';

    # `mkBefore` to ensure that any custom prompts would be visible.
    boot.initrd.preFailCommands = mkIf (!config.boot.initrd.systemd.enable) (mkBefore ''
      plymouth quit --wait
    '');

  };

}
