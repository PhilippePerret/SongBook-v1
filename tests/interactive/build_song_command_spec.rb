# frozen_string_literal: true

require_relative "../spec_helper"
require "cli"
require "fileutils"
require "tmpdir"

# `build` sur une chanson (Phil, 2026-08-27) : succès (vert) AVANT tout, puis nombre de
# conflits (rouge) s'il y en a, puis proposition (bleue) d'ouvrir le fichier des
# conflits, puis proposition d'ouvrir le PDF généré — dans cet ordre précis.
RSpec.describe "commande build (chanson)" do
  let(:prompt) { instance_double(TTY::Prompt) }

  before { allow(TTY::Prompt).to receive(:new).and_return(prompt) }

  describe "chanson sans conflit" do
    let(:export_dir) { File.join(FIXTURE_SONGS_DIR, "Angie", "export") }
    after { FileUtils.rm_rf(export_dir) }

    it "annonce le succès en vert, ne parle d'aucun conflit, propose d'ouvrir le PDF en bleu" do
      expect(prompt).to receive(:yes?).with(CLI.blue(Loc.get("song_build_open_pdf_question"))).and_return(false)

      expect { CLI.run(%w[build Angie], interactive: true) }
        .to output("#{AnsiColors::SUCCESS}👍 Chanson Angie générée en PDF.#{AnsiColors::RESET}\n").to_stdout
    end

    it "ouvre le PDF si on répond oui" do
      allow(prompt).to receive(:yes?).and_return(true)
      expect(CLI).to receive(:system).with("open", end_with(".pdf"))

      CLI.run(%w[build Angie], interactive: true)
    end
  end

  describe "chanson avec des conflits" do
    def build_with_conflicts
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "c.lyr"), "{couplet-1}\n/Zzz9:Un accord qui n'existe pas\n")
        File.write(File.join(dir, "c.infos"), "title: Test Conflits\n")
        yield dir
      end
    end

    it "signale le nombre de conflits en rouge, PUIS propose (en bleu) d'ouvrir le fichier des conflits, PUIS le PDF" do
      build_with_conflicts do |dir|
        expect(prompt).to receive(:yes?).with(CLI.blue(Loc.get("song_build_open_conflicts_question"))).ordered.and_return(false)
        expect(prompt).to receive(:yes?).with(CLI.blue(Loc.get("song_build_open_pdf_question"))).ordered.and_return(false)

        expect { CLI.run(["build", dir], interactive: true) }
          .to output(/\A#{Regexp.escape("#{AnsiColors::SUCCESS}👍 Chanson Test Conflits générée en PDF.#{AnsiColors::RESET}")}\n#{Regexp.escape(AnsiColors::ERROR)}Des conflits ont été rencontrés en cours de construction \(\d+\)\.#{Regexp.escape(AnsiColors::RESET)}\n\z/).to_stdout
      end
    end

    it "ouvre le fichier des conflits si on répond oui" do
      build_with_conflicts do |dir|
        allow(prompt).to receive(:yes?).and_return(true, false)
        expect(CLI).to receive(:system).with("open", end_with("-conflicts.log"))

        CLI.run(["build", dir], interactive: true)
      end
    end
  end
end
