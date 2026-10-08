# frozen_string_literal: true

# Runs every Ruby test: ruby -Itest test/run_all.rb
Dir.glob(File.join(__dir__, "test_*.rb")).sort.each { |f| require f }
