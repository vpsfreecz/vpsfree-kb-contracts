{
  description = "Reproducible vpsAdmin knowledge-base screenshots";

  inputs = {
    vpsadmin.url = "github:vpsfreecz/vpsadmin/cda461f8aca81518cec6723117efa55aa2308002";
    vpsadminos.follows = "vpsadmin/vpsadminos";
    vpsfStatus = {
      url = "github:vpsfreecz/vpsf-status/master";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.vpsadmin.follows = "vpsadmin";
      inputs.vpsadminos.follows = "vpsadminos";
    };
    nixpkgs.follows = "vpsadminos/nixpkgs";
    toolsNixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
      toolsNixpkgs,
      vpsadmin,
      vpsadminos,
      vpsfStatus,
      ...
    }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;

      env =
        name: default:
        let
          value = builtins.getEnv name;
        in
        if value == "" then default else value;

      slug = env "VPSADMIN_DEVCLUSTER_SLUG" "kb-captures";
      topology = env "VPSADMIN_DEVCLUSTER_TOPOLOGY" "single";
      networkMode = env "VPSADMIN_DEVCLUSTER_NETWORK" "bridge";
      bridgeHelper = env "VPSADMIN_DEVCLUSTER_BRIDGE_HELPER" "/run/wrappers/bin/qemu-bridge-helper";
      certDir = env "VPSADMIN_DEVCLUSTER_CERT_DIR" (toString ./cluster);
      clusterConfigFile = env "VPSADMIN_DEVCLUSTER_CONFIG_FILE" "";
      sshPubKey = env "VPSADMIN_DEVCLUSTER_SSH_PUBKEY" (toString ./cluster/placeholder-authorized-key.pub);
      vpsadminSourcePath = env "VPSADMIN_DEVCLUSTER_VPSADMIN_SOURCE" vpsadmin.outPath;
      vpsadminosSourcePath = env "VPSADMIN_DEVCLUSTER_VPSADMINOS_SOURCE" vpsadminos.outPath;
      haveapiSourcePath = env "VPSADMIN_DEVCLUSTER_HAVEAPI_SOURCE" "";
      configSourcePath = env "VPSADMIN_DEVCLUSTER_CONFIG_SOURCE" "";
      notificationTemplatesSourcePath = env "VPSADMIN_DEVCLUSTER_NOTIFICATION_TEMPLATES_SOURCE" "";
      webSourcePath = env "VPSADMIN_DEVCLUSTER_WEB_SOURCE" "";
      vpsfStatusSourcePath = env "VPSADMIN_DEVCLUSTER_VPSF_STATUS_SOURCE" "";
      vpsadminGoClientSourcePath = env "VPSADMIN_DEVCLUSTER_VPSADMIN_GO_CLIENT_SOURCE" "";
      telegramSecretsSourcePath = env "VPSADMIN_DEVCLUSTER_TELEGRAM_SECRETS" "";
      telegramEnable = env "VPSADMIN_DEVCLUSTER_TELEGRAM_ENABLE" "0";

      pkgs = import nixpkgs {
        inherit system;
        overlays = import (vpsadminos.outPath + "/os/overlays") {
          inherit (vpsadminos.inputs) netlinkrb ruby-lxc;
        };
      };
      toolPkgs = import toolsNixpkgs { inherit system; };
      fontConfig = toolPkgs.makeFontsConf {
        fontDirectories = [ toolPkgs.liberation_ttf ];
      };

      clusterTest = import ./cluster/nix/test.nix {
        inherit
          lib
          vpsadmin
          vpsadminos
          vpsfStatus
          slug
          topology
          networkMode
          bridgeHelper
          certDir
          clusterConfigFile
          sshPubKey
          vpsadminSourcePath
          vpsadminosSourcePath
          haveapiSourcePath
          configSourcePath
          notificationTemplatesSourcePath
          webSourcePath
          vpsfStatusSourcePath
          vpsadminGoClientSourcePath
          telegramEnable
          telegramSecretsSourcePath
          ;
      };

      clusterConfig = import (vpsadminos.outPath + "/tests/make-test.nix") clusterTest {
        inherit system;
        pkgs = nixpkgs.outPath;
        extraArgs = { inherit vpsadminos; };
      };

      ruby = pkgs.ruby_vpsadminos;
      runnerDeps = pkgs.bundlerEnv {
        name = "vpsadmin-kb-capture-runner-deps";
        gemfile = vpsadminos.outPath + "/os/packages/test-runner/Gemfile";
        lockfile = vpsadminos.outPath + "/os/packages/test-runner/Gemfile.lock";
        gemset = vpsadminos.outPath + "/os/packages/test-runner/gemset.nix";
        groups = [ "default" ];
        inherit ruby;
        gemConfig = pkgs.vpsadminosRubyGemConfig;
      };

      runner = pkgs.writeShellScriptBin "vpsadmin-kb-capture-cluster-runner" ''
        export GEM_HOME=${runnerDeps}/${ruby.gemPath}
        export GEM_PATH=${runnerDeps}/${ruby.gemPath}
        export RUBYLIB=${./cluster/lib}:${vpsadminos.outPath}/test-runner/lib:${vpsadminos.outPath}/osvm/lib:${vpsadminos.outPath}/libosctl/lib

        exec ${ruby}/bin/ruby ${./cluster/lib/runner.rb} "$@"
      '';
    in
    {
      packages.${system} = {
        cluster-config = clusterConfig.json;
        inherit runner;
        default = clusterConfig.json;
      };

      apps.${system} = {
        runner = {
          type = "app";
          program = "${runner}/bin/vpsadmin-kb-capture-cluster-runner";
        };
        default = self.apps.${system}.runner;
      };

      devShells.${system}.default = toolPkgs.mkShell {
        packages = with toolPkgs; [
          jq
          nodejs
          openssh
          openssl
          fontconfig
          liberation_ttf
          playwright-test
          procps
          ruby
          shellcheck
          util-linux
          vpsfree-client
        ];

        PLAYWRIGHT_BROWSERS_PATH = "${toolPkgs.playwright-driver.browsers}";
        NODE_PATH = "${toolPkgs.playwright-test}/lib/node_modules";
        FONTCONFIG_FILE = fontConfig;
        VPSADMIN_KB_VPSADMIN_SOURCE = vpsadmin.outPath;
      };
    };
}
