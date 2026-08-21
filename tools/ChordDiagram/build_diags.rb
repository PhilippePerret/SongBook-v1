#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "generate_chord_diagrams"

VERT = "\e[32m"
ROUGE = "\e[31m"
RESET = "\e[0m"

HELP_TEXT = <<~TXT
  build-diags — génère les diagrammes SVG manquants à partir des schemas.txt

  Usage : build-diags [-h | --help] [accord ...]

  Sans argument : génère tous les diags manquants sous assets/chords_diags/.
  Avec une liste d'accords (ex. build-diags A-0 Cd-4) : ne traite que ceux-là.
TXT

if ARGV.include?("-h") || ARGV.include?("--help")
  puts HELP_TEXT
  exit
end

def raccourci(chemin) = chemin.sub(Dir.home, "~")

only = ARGV.empty? ? nil : ARGV
created, skipped = GenerateChordDiagrams.run(only: only)

created.each { |c| puts "#{VERT}👍 #{raccourci(c[:path])}#{RESET}" }
skipped.each do |s|
  msg = s[:error] ? "#{s[:line]} — #{s[:error]}" : s[:line]
  puts "#{ROUGE}👎 #{raccourci(s[:schema_path])} : #{msg}#{RESET}"
end

if skipped.empty?
  puts "#{VERT}diags créés#{RESET}" if created.size != 1
else
  puts "#{ROUGE}Échecs :#{RESET}"
  skipped.each do |s|
    msg = s[:error] ? "#{s[:line]} — #{s[:error]}" : s[:line]
    puts "#{ROUGE}👎 #{raccourci(s[:schema_path])} : #{msg}#{RESET}"
  end
  puts "#{ROUGE}#{created.size} succès, #{skipped.size} échec(s).#{RESET}"
end
