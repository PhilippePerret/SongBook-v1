# frozen_string_literal: true

require_relative "../spec_helper"
require "cli"
require "fileutils"
require "tmpdir"

# Tests des outils
RSpec.describe "commande build diag" do
  it "Construire un diagramme d'accord à partir d'un schéma" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        CLI.run(["build", "diag", "Am-0 : 10 21/1 32/3 42/2 50 6x"], interactive: true)
        expect(File.exist?("Am-0.svg")).to be true
      end
    end
  end

  it "Refuser un schéma illisible" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        expect { CLI.run(["build", "diag", "n'importe quoi"], interactive: true) }.to raise_error(SystemExit)
      end
    end
  end
end

# Tests des outils
RSpec.describe "commande build tab" do
  let(:song_folder) { File.join(FIXTURE_SONGS_DIR, "Angie") }
  let(:tab_path) { File.join(song_folder, "riff-test.tab") }
  let(:svg_path) { File.join(song_folder, "riff-test.svg") }

  after { [tab_path, svg_path].each { |f| File.delete(f) if File.exist?(f) } }

  it "Construire les tablatures d'une chanson trouvée par son titre" do
    File.write(tab_path, "---\ntitle: Riff Test\n---\n50/4 <10 21>/4\n")

    CLI.run(%w[build tab Angie], interactive: true)

    expect(File.exist?(svg_path)).to be true
  end

  it "Dire qu'il n'y a rien à construire si la chanson n'a pas de tablature" do
    expect { CLI.run(%w[build tab Angie], interactive: true) }.not_to raise_error
  end
end
