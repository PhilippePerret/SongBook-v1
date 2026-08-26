# frozen_string_literal: true

require_relative "../spec_helper"
require "songbook_creator"
require "fileutils"

# Tests des carnets
RSpec.describe "assistant de création de carnet" do
  let(:prompt) { instance_double(TTY::Prompt) }
  let(:created_folder) { File.join(FIXTURE_SONGBOOKS_DIR, "Carnet-De-Test-Assistant") }

  before do
    allow(TTY::Prompt).to receive(:new).and_return(prompt)
    allow(SongbookCreator).to receive(:system).and_return(true)
  end

  after { FileUtils.rm_rf(created_folder) }

  it "Créer un carnet avec les bonnes données" do
    allow(prompt).to receive(:ask).with("Titre du carnet :").and_return("Mon Carnet Test")
    allow(prompt).to receive(:ask).with("Nom du dossier :", default: "Carnet-mon-carnet-test").and_return("Carnet-De-Test-Assistant")
    allow(prompt).to receive(:ask).with("Sous-titre (rien si aucun) :").and_return("Le sous-titre")
    allow(prompt).to receive(:ask).with("Prix (ex. 9,90 € — rien si inconnu) :").and_return("9,90 €")
    allow(prompt).to receive(:ask).with("Nom de l'éditeur (rien si aucun) :").and_return("")
    allow(prompt).to receive(:ask).with("Conception du carnet (rien si inconnu) :").and_return("Philippe")
    allow(prompt).to receive(:yes?).and_return(false)

    folder = SongbookCreator.run

    expect(folder).to eq(created_folder)
    infos = CarnetBuilder.parse_nested_infos(File.join(created_folder, "c.infos"))
    expect(infos["title"]).to eq("Mon Carnet Test")
    expect(infos["subtitle"]).to eq("Le sous-titre")
    expect(infos["price"]).to eq("9,90 €")
    expect(infos["credits"]["book_designer"]).to eq("Philippe")
    expect(File.exist?(File.join(created_folder, "c.tdm"))).to be true
  end

  it "Retrouver un carnet déjà créé au lieu d'en refaire un" do
    FileUtils.mkdir_p(created_folder)
    File.write(File.join(created_folder, "c.infos"), "title: Déjà Là\n")
    allow(prompt).to receive(:ask).with("Titre du carnet :").and_return("Peu importe")
    allow(prompt).to receive(:ask).with("Nom du dossier :", default: "Carnet-peu-importe").and_return("Carnet-De-Test-Assistant")
    allow(prompt).to receive(:yes?).and_return(false)

    result = SongbookCreator.run

    expect(result).to be_nil
    # le fichier existant n'a pas été écrasé
    expect(File.read(File.join(created_folder, "c.infos"))).to eq("title: Déjà Là\n")
  end
end
