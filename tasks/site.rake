require "fileutils"
require "shellwords"

# The board's guide and tutorials (site/, VitePress), with the console
# (sim/) bundled in. Node runs in the stock node image; nothing on the host.
# See site/README.md.
namespace :site do
  compose = "docker compose -f #{Shellwords.escape("#{MRUBY_ROOT}/docker/compose.yml")}"
  env = "HOST_UID=#{Process.uid} HOST_GID=#{Process.gid}"
  env += " SITE_BASE=#{Shellwords.escape(ENV["SITE_BASE"])}" if ENV["SITE_BASE"]
  dist = "#{MRUBY_ROOT}/site/.vitepress/dist"

  task :install do
    next if File.exist?("#{MRUBY_ROOT}/site/node_modules/.package-lock.json")
    sh "#{env} #{compose} run --rm site npm ci --no-fund --no-audit"
  end

  desc "Write the guide while watching it (http://localhost:5173/adventure-board/)"
  task dev: :install do
    sh "#{env} #{compose} run --rm --service-ports site npm run dev"
  end

  desc "Build the guide with the console into site/.vitepress/dist"
  task build: :install do
    sh "#{env} #{compose} run --rm site npm run build"
    Rake::Task["site:console"].invoke
    puts "site/.vitepress/dist is ready; `rake site:preview` to look at it."
  end

  desc "Serve the built site as it will be published"
  task :preview do
    abort "#{dist} is not built; run `rake site:build`." unless File.exist?("#{dist}/index.html")
    sh "#{env} #{compose} run --rm --service-ports site npm run preview"
  end

  # The console is sim/ as it is, beside the files it reads from the
  # repository (lib/, examples/, mrbgems/...) at window.REPO_ROOT, so that the
  # same page runs here and under `rake sim:server`. Only what the page asks
  # for is copied, not the repository.
  copy_console = lambda do |out, repo|
    FileUtils.rm_rf [out, "#{repo}/lib", "#{repo}/examples", "#{repo}/mrbgems"]
    FileUtils.mkdir_p [out, "#{repo}/lib", "#{repo}/examples"]
    Dir.children("#{MRUBY_ROOT}/sim").each do |name|
      next if %w[README.md test].include?(name)
      FileUtils.cp_r "#{MRUBY_ROOT}/sim/#{name}", out
    end
    FileUtils.cp_r ["#{MRUBY_ROOT}/lib/adventure_board.rb", "#{MRUBY_ROOT}/lib/adventure_board"], "#{repo}/lib"
    # .mrb too: a program built ahead with the library in it (examples/game.mrb).
    FileUtils.cp Dir["#{MRUBY_ROOT}/examples/*.{rb,mrb}"], "#{repo}/examples"
    # The gems whose Ruby the page loads (the M + '...' entries in index.html).
    File.read("#{MRUBY_ROOT}/sim/index.html").scan(%r{M \+ '([^']+)'}).flatten.each do |path|
      FileUtils.mkdir_p File.dirname("#{repo}/mrbgems/#{path}")
      FileUtils.cp "#{MRUBY_ROOT}/mrbgems/#{path}", "#{repo}/mrbgems/#{path}"
    end
    unless File.exist?("#{out}/vendor/picoruby.wasm")
      warn "warning: sim/vendor is missing, so the console falls back to the stock " \
           "wasm from the CDN (no kanji, no colours). Run `rake sim:wasm` first."
    end
  end

  # Into the built guide, at console/ with the repository's files beside it.
  task :console do
    abort "#{dist} is not built" unless File.directory?(dist)
    copy_console.call("#{dist}/console", dist)
  end

  # The console as a site of its own (picorubykaigi.org/adventure-board-console/):
  # the page at the top and the repository's files in repo/.
  desc "Assemble the console on its own into tmp/console (or OUT=dir)"
  task :console_standalone do
    out = File.expand_path(ENV["OUT"] || "#{MRUBY_ROOT}/tmp/console")
    copy_console.call(out, "#{out}/repo")
    page = "#{out}/index.html"
    html = File.read(page)
    line = "window.REPO_ROOT = '../';"
    abort "#{page}: #{line} not found" unless html.include?(line)
    File.write(page, html.sub(line, "window.REPO_ROOT = './repo/';"))
    puts "#{out} is ready."
  end
end
