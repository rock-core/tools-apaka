require 'bundler/gem_tasks'
require 'rake/testtask'
require 'yard'

task 'default'
task 'gem' => 'build'
task 'doc' => 'yard'

Rake::TestTask.new(:test) do |t|
    t.libs << "lib" << Dir.pwd
    t.test_files = FileList['test/test_*.rb']
end

YARD::Rake::YardocTask.new do |t|
    t.files = ['lib/**/*.rb']
    t.options = ['--any','--extra','--options']
  #  t.stats_options = ['--list-undoc']
end
