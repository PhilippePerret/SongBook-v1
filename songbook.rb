#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/cli"

if ARGV.delete("-i") || ARGV.delete("--interactive")
  CLI.run_interactive
else
  CLI.run(ARGV)
end
