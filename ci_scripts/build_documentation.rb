#!/usr/bin/env ruby

require 'cocoapods'
require 'jazzy'
require 'fileutils'
require 'mustache'
require 'optparse'
require 'pathname'
require 'yaml'

def info(string)
  puts "[#{File.basename(__FILE__)}] [INFO] #{string}"
end

def die(string)
  abort "[#{File.basename(__FILE__)}] [ERROR] #{string}"
end

# Joins the given strings. If one or more arguments is nil or empty, an exception is raised.
def File.join_if_safe(arg1, *otherArgs)
  args = [arg1] + otherArgs

  # Check for empty or nil strings
  args.each do |arg|
    raise "Cannot join nil or empty string." if arg.nil? || arg.empty?
  end

  return File.join(args)
end

# MARK: - constants

$SCRIPT_DIR = __dir__
$ROOT_DIR = File.expand_path("..", $SCRIPT_DIR)
$JAZZY_CONFIG_FILE = File.join_if_safe($ROOT_DIR, ".jazzy.yaml")
$JAZZY_CONFIG = YAML.load_file($JAZZY_CONFIG_FILE)

# MARK: - build docs

# Note(mludowise): When `check_documentation.sh` locally, we want to save docs
# to a temp directory so we can check undocumented.json and grep for `@_spi`,
# without unintentially committing changes to the `/docs` folder.
def get_docs_root_directory
  docs_root_directory = $ROOT_DIR

  OptionParser.new do |opts|
    opts.on("--docs-root-dir DIRECTORY", "Generate docs to this directory instead of the repo's root directory.") do |dir|
      docs_root_directory = File.expand_path(dir, Dir.getwd)
    end
  end.parse!

  return docs_root_directory
end

# Create temp podspec directory
# NOTE(mludowise|https://github.com/realm/jazzy/issues/1262):
# This won't be needed if jazzy ever allows for multiple development pods
def make_temp_spec_repo
  make_spec_repo_output = `#{$SCRIPT_DIR}/make_temp_spec_repo.sh`
  make_spec_repo_status=$?.exitstatus

  unless make_spec_repo_status == 0
    die "Unable to create pod spec repo."
  end

  temp_spec_dir = make_spec_repo_output.lines.last.strip
  info "Sucessfully created podspec repo at \`#{temp_spec_dir}\`"
  return temp_spec_dir
end

# Clean pod cache to always use latest local copy of pod dependencies
# NOTE(mludowise|https://github.com/realm/jazzy/issues/1262):
# This won't be needed if jazzy ever allows for multiple development pods
def clean_pod_cache
  info "Cleaning pod cache..."
  Dir.glob("#{$ROOT_DIR}/*.podspec").each do |file|
    podspec = Pod::Specification.from_file(file)
    cmd = Pod::Command::Cache::Clean.new(CLAide::ARGV.new([podspec.name, '--all']))
    cmd.run
  end
end

def docs_title(release_version)
 return "Stripe iOS SDKs #{release_version}"
end

# Execute jazzy
def build_module_docs(modules, release_version, docs_root_directory, temp_spec_dir)
  jazzy_exit_code = 0

  modules.each do |m|

    # Note: If we don't check for empty string/nil, then jazzy will silently
    # overwrite the entire git repo directory.
    output = m['docs']['output'].to_s
    if output.empty?
      die "Missing required docs config \`output\`. Update modules.yaml."
    end

    # Prepend `docs_root_directory`
    output = File.expand_path(output, docs_root_directory).to_s

    info "Executing jazzy for #{m['podspec']}..."
    `jazzy \
      --config "#{$JAZZY_CONFIG_FILE}" \
      --output "#{output}" \
      --github-file-prefix "https://github.com/stripe/stripe-ios/tree/#{release_version}" \
      --title "#{docs_title(release_version)}" \
      --podspec "#{File.join_if_safe($ROOT_DIR, m['podspec'])}" \
      --pod-sources "file://#{temp_spec_dir}"`

    # Verify jazzy exit code
    jazzy_exit_code=$?.exitstatus

    if jazzy_exit_code != 0
      die "Executing jazzy failed with status code: #{jazzy_exit_code}"
    end
  end
end

# Creates html that lists all modules with docs enabled and links to their docs
# directory. The descriptions of the modules are from their podspec summaries.
def index_page_content(modules)
  view = Mustache.new
  view.template_file = File.join_if_safe($ROOT_DIR, $JAZZY_CONFIG['theme'], "templates", "index.mustache")

  view[:modules] = modules.map do |m|
    # Get get module's docs output relative to `docs` folder
    relative_path = Pathname.new(m['docs']['output']).relative_path_from(Pathname.new('docs'))

    # Load podspec to get module name and summary
    podspec = Pod::Specification.from_file(File.join_if_safe($ROOT_DIR, m['podspec']))

    props={}
    props[:name] = podspec.name
    props[:summary] = podspec.summary
    props[:directory] = relative_path.to_s
    props
  end

  return view.render
end

# Builds the `/docs/index.html` page
def build_index_page(modules, release_version, docs_root_directory)
  info "Building index page..."

  # Reuse Jazzy theme so it's visually consistent with the reset of the docs
  view = Mustache.new
  view.template_name = "doc"
  view.template_path = File.join_if_safe($ROOT_DIR, $JAZZY_CONFIG['theme'], "templates")

  # Add properties expected by template
  # Copied & modified from https://github.com/realm/jazzy
  config = YAML.load_file(File.join_if_safe($ROOT_DIR, ".jazzy.yaml"))
  view[:copyright] = (
    date = DateTime.now.strftime('%Y-%m-%d')
    year = date[0..3]
    "&copy; #{year} <a class=\"link\" href=\"#{$JAZZY_CONFIG['author_url']}\"" \
    "target=\"_blank\" rel=\"external\">#{$JAZZY_CONFIG['author']}</a>. " \
    "All rights reserved. (Last updated: #{date})"
  )
  view[:jazzy_version] = Jazzy::VERSION
  view[:objc_first] = false
  view[:language_stub] = 'swift'
  view[:disable_search] = false
  view[:docs_title] = docs_title(release_version)
  view[:module_version] = release_version
  view[:github_url] = $JAZZY_CONFIG['github_url']
  view[:name] = docs_title(release_version)

  # Don't render search since it won't work for the index page
  view[:disable_search] = true

  # Custom template var for our theme to disable some html for the root index page
  view[:is_root_index] = true

  # Insert generated html
  view[:overview] = index_page_content(modules)

  # Write to docs/index.html
  output_file = File.join_if_safe(docs_root_directory, "docs", "index.html")
  File.open(output_file, 'w') { |file| file.write(view.render) }
end

# Jazzy compiles assets from the theme's assets directory and saves them to each
# module's docs directory. We're going to move one set of them to the docs/ root
# directory and symlink the rest. It's a bit hacky but it reduces duplicate
# css/js/images in our repo and moves it to an expected location that
# docs/index.html wants.
def fix_assets(modules, docs_root_directory)
  docs_dir = File.expand_path('docs', docs_root_directory)

  # Get list of assets used by theme (js, img, css, etc)
  Dir.glob(File.join_if_safe($ROOT_DIR, $JAZZY_CONFIG['theme'], "assets", "*")).each do |asset_file|
    asset_base_name = File.basename(asset_file)

    # Delete old asset copies from /docs directory
    FileUtils.rm_rf(File.join_if_safe(docs_dir, asset_base_name))

    modules.each_with_index do |m, index|
      module_docs_dir = File.join_if_safe(docs_root_directory, m['docs']['output'])
      compiled_asset_path = File.join_if_safe(module_docs_dir, asset_base_name)

      if index == 0
        # Move the compiled asset from the module's docs folder into `/docs` so index.html can use it
        FileUtils.mv(compiled_asset_path, File.join_if_safe(docs_dir, asset_base_name))
      else
        # Delete the compiled asset from the module's docs folder
        FileUtils.rm_rf(compiled_asset_path)
      end

      # Symlink so each module's docs folder can use root `/docs` folder's assets
      Dir.chdir(module_docs_dir){
        File.symlink(File.join_if_safe(docs_dir, asset_base_name), compiled_asset_path)
      }
    end
  end
end

# MARK: - main

temp_spec_dir = make_temp_spec_repo()

begin
  clean_pod_cache()
  docs_root_directory = get_docs_root_directory()

  # Load modules from yaml and filter out any which don't have docs configured
  modules = YAML.load_file(File.join_if_safe($ROOT_DIR, "modules.yaml"))['modules'].select { |m| !m['docs'].nil? }
  release_version = `cat "#{$ROOT_DIR}/VERSION"`.strip
  build_module_docs(modules, release_version, docs_root_directory, temp_spec_dir)
  build_index_page(modules, release_version, docs_root_directory)
  fix_assets(modules, docs_root_directory)
ensure
  # Always cleanup temp podspec directory
  info "Deleting podspec repo at `#{temp_spec_dir}`"
  FileUtils.rm_rf(temp_spec_dir)
end