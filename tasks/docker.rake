# Rake front-end for the container build environment under docker/.
#
# The firmware toolchain (arm-none-eabi-gcc, cmake, picotool and Ruby 3.4)
# lives in the image built from docker/Dockerfile, so these tasks mirror the
# native `r2p2:{vm}:{board}:{mode}` namespace for hosts that do not have the
# toolchain installed:
#
#   rake docker:r2p2:picoruby:pico2_w:prod
#
# The work itself is done by docker/build.sh inside the container, which runs
# the same rake tasks and additionally copies the finished .uf2/.elf to dist/.
#
# `docker:flash:...` mirrors the same targets and programs the board over SWD
# through a CMSIS-DAP probe with the openocd built into the image, so no
# toolchain and no probe driver have to exist on the host either.

require "shellwords"

DOCKER_COMPOSE_FILE = "#{MRUBY_ROOT}/docker/compose.yml"
DOCKER_IMAGE = "adventure-board-firmware:latest"

# Environment variables the native r2p2 tasks read. They are turned into cmake
# defines by tasks/picoruby/r2p2.rake, so forwarding the ones that are set on
# the host keeps `rake docker:r2p2:...` behaving like `rake r2p2:...`.
DOCKER_FORWARDED_ENV = %w[
  PICORUBY_PSG_MCP4922_DMA
  PICORUBY_PSG_PWM_DMA
  R2P2_NO_SHARED_ALLOC
  R2P2_CONSOLE_UART
  R2P2_USB_MIDI
  ADAPTER_SPEED
  ELF
].freeze

def docker_compose_bin
  @docker_compose_bin ||=
    if system("docker compose version", out: File::NULL, err: File::NULL)
      "docker compose"
    elsif system("docker-compose version", out: File::NULL, err: File::NULL)
      "docker-compose"
    else
      raise "Docker Compose is not available. See docker/README.md."
    end
end

# The container writes into the bind-mounted working tree, so it runs as the
# invoking user rather than as root; docker/compose.yml reads these.
def docker_compose_env
  "HOST_UID=#{Process.uid} HOST_GID=#{Process.gid}"
end

def docker_compose_run(service, *args, env: {})
  opts = env.map {|k, v| "-e #{Shellwords.escape("#{k}=#{v}")}" }
  DOCKER_FORWARDED_ENV.each do |name|
    opts << "-e #{Shellwords.escape("#{name}=#{ENV[name]}")}" if ENV[name]
  end
  sh [
    docker_compose_env,
    docker_compose_bin,
    "-f #{Shellwords.escape(DOCKER_COMPOSE_FILE)}",
    "run --rm",
    *opts,
    service,
    *args.map {|a| Shellwords.escape(a) },
  ].join(" ")
end

namespace :docker do
  desc "Build the Docker image holding the firmware toolchain"
  task :image do
    sh "#{docker_compose_env} #{docker_compose_bin} -f #{Shellwords.escape(DOCKER_COMPOSE_FILE)} build"
  end

  # Building the image takes several minutes, so it is not a dependency of
  # every build task; it is only built when it does not exist yet. Use
  # `rake docker:image` to rebuild it after editing docker/Dockerfile.
  task :ensure_image do
    unless system("docker image inspect #{DOCKER_IMAGE}", out: File::NULL, err: File::NULL)
      Rake::Task["docker:image"].invoke
    end
  end

  desc "Open a shell in the Docker build environment"
  task :shell => :ensure_image do
    docker_compose_run("shell")
  end

  desc "Remove the Docker image and the bundle volume"
  task :clean do
    sh "#{docker_compose_env} #{docker_compose_bin} -f #{Shellwords.escape(DOCKER_COMPOSE_FILE)} down -v"
    sh "docker image rm -f #{DOCKER_IMAGE}"
  end

  namespace :r2p2 do
    %w[femtoruby picoruby].each do |vm|
      namespace vm do
        %w[pico pico_w pico2 pico2_w].each do |board|
          next unless File.exist?(r2p2_mruby_config(vm, board))

          namespace board do
            %w[debug prod].each do |mode|
              desc "Build R2P2 #{vm} for #{board} (#{mode}) in Docker, into dist/"
              task mode => "docker:ensure_image" do
                docker_compose_run("build", env: {"VM" => vm, "BOARD" => board, "MODE" => mode})
              end
            end

            desc "Clean R2P2 #{vm} for #{board} (both debug and prod) in Docker"
            task :clean => "docker:ensure_image" do
              docker_compose_run("shell", "rake", "r2p2:#{vm}:#{board}:clean")
            end
          end
        end
      end
    end
  end

  namespace :flash do
    %w[femtoruby picoruby].each do |vm|
      namespace vm do
        %w[pico pico_w pico2 pico2_w].each do |board|
          next unless File.exist?(r2p2_mruby_config(vm, board))

          namespace board do
            %w[debug prod].each do |mode|
              desc "Flash R2P2 #{vm} #{board} (#{mode}) over SWD via a CMSIS-DAP probe"
              task mode => "docker:ensure_image" do
                begin
                  docker_compose_run("flash", env: {"VM" => vm, "BOARD" => board, "MODE" => mode})
                rescue RuntimeError
                  # openocd has already said what went wrong; a rake backtrace
                  # on top of it only buries the message. The probe not being
                  # forwarded into WSL is by far the most common cause.
                  abort <<~MSG
                    Flashing failed. If openocd said "unable to find a matching
                    CMSIS-DAP device", the probe is not attached to WSL. From an
                    administrator PowerShell on Windows:
                      usbipd list
                      usbipd attach --wsl --busid <BUSID>
                    See docker/README.md for the rest.
                  MSG
                end
              end
            end
          end
        end
      end
    end
  end
end
