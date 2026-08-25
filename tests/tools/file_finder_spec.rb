# frozen_string_literal: true

require_relative "../spec_helper"
require "file_finder"
require "tmpdir"

# Tests des outils
RSpec.describe "recherche d'un fichier par type" do
  it "Trouver un fichier avec sa forme longue (paroles.lyrics)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "c.lyrics"), "")
      expect(File.basename(FileFinder.find(dir, :lyr))).to eq("c.lyrics")
    end
  end

  it "Trouver un fichier avec sa forme courte (paroles.lyr)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "c.lyr"), "")
      expect(File.basename(FileFinder.find(dir, :lyr))).to eq("c.lyr")
    end
  end

  it "Trouver un fichier même sans nom devant l'extension (juste .lyr)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".lyr"), "")
      expect(FileFinder.find(dir, :lyr)).not_to be_nil
    end
  end

  it "Ne rien trouver si le fichier n'existe pas" do
    Dir.mktmpdir do |dir|
      expect(FileFinder.find(dir, :lyr)).to be_nil
    end
  end
end
