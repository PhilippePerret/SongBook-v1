# frozen_string_literal: true

require_relative "../spec_helper"
require "app_config"

# `AppConfig.ensure_folder` : revérifie le dossier configuré à CHAQUE appel (Phil,
# 2026-08-28 : "s'assurer à chaque fois que ce dossier existe bien et le redemander
# s'il a été déplacé, supprimé ou autre") — pas juste demandé une fois puis considéré
# acquis. Partagée par `songs_dir`/`songbooks_dir`.
RSpec.describe "AppConfig.ensure_folder" do
  def silence_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end

  it "chemin déjà configuré ET existant : renvoyé tel quel, aucune question posée" do
    allow(AppConfig).to receive(:get).with("k").and_return(Dir.pwd)
    expect(AppConfig).not_to receive(:set)
    expect($stdin).not_to receive(:gets)

    expect(AppConfig.ensure_folder("k", "Question")).to eq(Dir.pwd)
  end

  it "chemin configuré mais dossier disparu depuis (déplacé/supprimé) : redemande au lieu de le renvoyer tel quel" do
    allow(AppConfig).to receive(:get).with("k").and_return("/ce/dossier/nexiste/plus/vraiment")
    allow($stdin).to receive(:gets).and_return("#{Dir.pwd}\n")
    expect(AppConfig).to receive(:set).with("k", Dir.pwd).and_return(Dir.pwd)

    silence_stdout { expect(AppConfig.ensure_folder("k", "Question")).to eq(Dir.pwd) }
  end

  it "aucun chemin configuré : redemande jusqu'à un dossier valide, enregistre seulement celui-là" do
    allow(AppConfig).to receive(:get).with("k").and_return(nil)
    allow($stdin).to receive(:gets).and_return("/nexiste/pas\n", "#{Dir.pwd}\n")
    expect(AppConfig).to receive(:set).with("k", Dir.pwd).and_return(Dir.pwd)

    silence_stdout do
      expect { AppConfig.ensure_folder("k", "Question") }.to output(/dossier introuvable/).to_stderr
    end
  end
end
