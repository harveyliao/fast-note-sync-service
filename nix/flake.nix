{
  description = "Fast Note Sync Service - self-hosted Obsidian sync server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
          fast-note-sync-service = pkgs.buildGoModule rec {
            pname = "fast-note-sync-service";
            version = "2.13.6";

            src = pkgs.fetchFromGitHub {
              owner = "haierkeys";
              repo = "fast-note-sync-service";
              rev = version;
              # 1st build: nix prints correct hash -> replace this placeholder
              hash = "sha256-sDjx0VkUpm6oWHjdsP7hmx/r1RhjeNeh/HMttN0II0A=";
            };

            # No vendor/ dir -> buildGoModule fetches deps.
            # 1st build: nix prints correct hash -> replace this placeholder
            vendorHash = "sha256-RgwwMJE2mm6ZtyBIInL5FWArEgm8gxj9wxJe9k3q1U4=";

            env.CGO_ENABLED = "0";
            doCheck = false;

            # frontend/ docs/ config/ are in the source tree,
            # go:embed picks them up during build automatically.

            ldflags = [ "-s" "-w" ];

            meta = with pkgs.lib; {
              description = "High-performance note syncing and REST API service for Obsidian";
              homepage = "https://github.com/haierkeys/fast-note-sync-service";
              license = licenses.asl20;
              mainProgram = "fast-note-sync-service";
              platforms = supportedSystems;
            };
          };

          default = self.packages.${system}.fast-note-sync-service;
        }
      );

      nixosModules.fast-note-sync-service = { config, lib, pkgs, ... }:
        let
          cfg = config.services.fast-note-sync-service;
          pkg = self.packages.${pkgs.stdenv.hostPlatform.system}.fast-note-sync-service;
          yamlFormat = pkgs.formats.yaml { };
          configFile = yamlFormat.generate "fns-config.yaml" cfg.settings;
        in {
          options.services.fast-note-sync-service = {
            enable = lib.mkEnableOption "Fast Note Sync Service";

            package = lib.mkOption {
              type = lib.types.package;
              default = pkg;
              description = "The fast-note-sync-service package to use.";
            };

            port = lib.mkOption {
              type = lib.types.port;
              default = 9000;
              description = "HTTP port for the service and WebSocket endpoint.";
            };

            dataDir = lib.mkOption {
              type = lib.types.str;
              default = "/var/lib/fast-note-sync";
              description = "Persistent data directory for storage, database, and logs.";
            };

            openFirewall = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Open the service port in the firewall.";
            };

            settings = lib.mkOption {
              type = yamlFormat.type;
              default = { };
              description = ''
                Attrset that becomes the full config.yaml.
                Sensible defaults are provided; override any field you need.
                Reference: https://github.com/haierkeys/fast-note-sync-service/blob/master/config/config.yaml
              '';
            };
          };

          config = lib.mkIf cfg.enable {
            # Set defaults (priority 1000) so user overrides (priority 100) win
            services.fast-note-sync-service.settings = {
              server = lib.mkDefault {
                http-port = ":${toString cfg.port}";
                run-mode = "release";
                read-timeout = 60;
                write-timeout = 60;
                mcp-sse-ping-interval = 30;
              };
              app = lib.mkDefault {
                default-page-size = 10;
                max-page-size = 100;
                default-context-timeout = 60;
                temp-path = "${cfg.dataDir}/storage/temp";
                is-return-sussess = false;
                soft-delete-retention-time = "7d";
                sync-log-retention-time = "30d";
                history-keep-versions = 100;
                history-save-delay = "10s";
                upload-session-timeout = "1d";
                file-chunk-size = "512KB";
                download-session-timeout = "1h";
                worker-pool-max-workers = 100;
                worker-pool-queue-size = 1000;
                write-queue-capacity = 1000;
                write-queue-timeout = "30s";
                write-queue-idle-time = "10m";
                ws-read-max-payload-size = "128MB";
                ws-write-max-payload-size = "128MB";
                ws-parallel-enabled = true;
                ws-parallel-golimit = 8;
                ws-check-utf8-enabled = true;
                ws-compression-enabled = true;
                ws-compression-level = 1;
                ws-compression-threshold = 512;
                log-save-fileurl = "${cfg.dataDir}/storage/logs/";
                log-file = "log.log";
                pull-source = "auto";
              };
              database = lib.mkDefault {
                type = "sqlite";
                path = "${cfg.dataDir}/storage/database/db.sqlite3";
                auto-migrate = true;
                max-open-conns = 100;
                max-idle-conns = 10;
                conn-max-lifetime = "30m";
                conn-max-idle-time = "10m";
                enable-write-queue = true;
              };
              log = lib.mkDefault {
                level = "warn";
                file = "${cfg.dataDir}/storage/logs/log.log";
                production = true;
              };
              security = lib.mkDefault {
                auth-token-key = "fast-note-sync-Auth-Token";
                token-expiry = "365d";
                share-token-key = "fns";
                share-token-expiry = "30d";
              };
              user = lib.mkDefault {
                register-is-enable = true;
                admin-uid = 0;
              };
              tracer = lib.mkDefault {
                enabled = true;
                header = "X-Trace-ID";
              };
              storage = lib.mkDefault {
                local-fs = {
                  is-enable = false;
                  httpfs-is-enable = true;
                  save-path = "${cfg.dataDir}/storage/uploads";
                };
              };
              webgui = lib.mkDefault {
                font-set = "local";
              };
              ngrok = lib.mkDefault {
                enabled = false;
              };
              cloudflare = lib.mkDefault {
                enabled = false;
              };
            };

            users.users.fast-note-sync = lib.mkDefault {
              isSystemUser = true;
              group = "fast-note-sync";
              home = cfg.dataDir;
            };
            users.groups.fast-note-sync = lib.mkDefault { };

            systemd.tmpfiles.rules = [
              "d ${cfg.dataDir} 0750 fast-note-sync fast-note-sync -"
              "d ${cfg.dataDir}/storage 0750 fast-note-sync fast-note-sync -"
              "d ${cfg.dataDir}/storage/database 0750 fast-note-sync fast-note-sync -"
              "d ${cfg.dataDir}/storage/uploads 0750 fast-note-sync fast-note-sync -"
              "d ${cfg.dataDir}/storage/temp 0750 fast-note-sync fast-note-sync -"
              "d ${cfg.dataDir}/storage/logs 0750 fast-note-sync fast-note-sync -"
              "d ${cfg.dataDir}/config 0750 fast-note-sync fast-note-sync -"
            ];

            systemd.services.fast-note-sync-service = {
              description = "Fast Note Sync Service";
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];
              wantedBy = [ "multi-user.target" ];

              serviceConfig = {
                ExecStart = "${cfg.package}/bin/fast-note-sync-service run -c ${configFile}";
                WorkingDirectory = cfg.dataDir;
                User = "fast-note-sync";
                Group = "fast-note-sync";
                Restart = "on-failure";
                RestartSec = 5;

                # Hardening
                ProtectSystem = "strict";
                ProtectHome = true;
                PrivateTmp = true;
                NoNewPrivileges = true;
                ReadWritePaths = [ cfg.dataDir ];
                ProtectKernelTunables = true;
                ProtectKernelModules = true;
                ProtectControlGroups = true;
                RestrictSUIDSGID = true;
              };
            };

            networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
          };
        };

      nixosModules.default = self.nixosModules.fast-note-sync-service;
    };
}
