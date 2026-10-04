# frozen_string_literal: true

require "bundler/gem_tasks"

# By default, run tests and linter.
task default: [:test, :rubocop]


require "rake/testtask"

Rake::TestTask.new do |t|
  t.libs = %w[lib test]
  t.pattern = "test/**/*_test.rb"
  t.verbose = !ENV["VERBOSE"].nil?
  t.warning = !ENV["WARNING"].nil?
end

begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new
rescue LoadError
  # rubocop not available in release environment
end


begin
  require "yard"
  require "yard/rake/yardoc_task"

  YARD::Rake::YardocTask.new(:yardoc) do |y|
    y.options = ["--output-dir", "yardoc"]
  end

  CLOBBER.include "yardoc"
rescue LoadError
  # yard not available in release environment
end


desc "Run all benchmarks in the benchmarks directory"
task :benchmarks do
  Dir["benchmarks/bm_*.rb"].each do |file|
    sh "ruby #{file}"
  end
end


desc "Downloads the Public Suffix List file from the repository and stores it locally."
task :"update-list" do
  require "net/http"

  definition_url = "https://raw.githubusercontent.com/publicsuffix/list/master/public_suffix_list.dat"

  File.open("data/list.txt", "w+") do |f|
    response = Net::HTTP.get_response(URI.parse(definition_url))
    response.body
    f.write(response.body)
  end
end

desc "Compare registration boundary changes between two Public Suffix List files"
task :"compare_lists", [:old_list, :new_list, :private_domains] do |_task, args|
  args.with_defaults(private_domains: ENV.fetch("PRIVATE_DOMAINS", "true"))
  private_domains = %w[1 true yes on].include?(args[:private_domains].to_s.downcase)

  if args[:old_list].nil? || args[:new_list].nil?
    abort "Usage: rake compare_lists[OLD_LIST,NEW_LIST]"
  elsif !%w[1 true yes on 0 false].include?(args[:private_domains].to_s.downcase)
    abort "PRIVATE_DOMAINS or the third task argument must be a boolean value"
  end

  require_relative "lib/public_suffix"
  changes = PublicSuffix.compare_lists(args[:old_list], args[:new_list],
                                      private_domains: private_domains)
  scope = private_domains ? "included" : "excluded"

  puts "Found #{changes.size} registration boundary change(s) (private domains #{scope})"
  changes.each do |change|
    puts
    puts "Family: #{change.family}"
    puts "Witness: #{change.witness}"
    puts "Old eTLD: #{change.old_etld || '(none)'}"
    puts "Old eTLD+1: #{change.old_registrable_domain || '(none)'}"
    puts "New eTLD: #{change.new_etld || '(none)'}"
    puts "New eTLD+1: #{change.new_registrable_domain || '(none)'}"
    next if change.excluded_families.empty?

    puts "Exception-canceled families: #{change.excluded_families.join(', ')}"
  end
end
