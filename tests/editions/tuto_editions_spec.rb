# frozen_string_literal: true

require_relative "../spec_helper"
require "icare_editions"
require "tmpdir"
require "yaml"

RSpec.describe "tuto-editions : dossier de la chanson sur le site des éditions" do
  let(:tmp) { Dir.mktmpdir }
  let(:items_dir) { File.join(tmp, "items") }
  let(:song_folder) { File.join(tmp, "Comme d'habitude") }

  before do
    FileUtils.mkdir_p(items_dir)
    FileUtils.mkdir_p(song_folder)
    File.write(File.join(song_folder, "c.infos"), <<~INF)
      id: comme-dhabitude-claude-francois-1967
      title: Comme d'habitude
      performer: Claude François
    INF
  end

  after { FileUtils.rm_rf(tmp) }

  it "crée le dossier au nom de l'id avec texte.md vide et data.yaml" do
    result = IcareEditions.create_song_item(song_folder, items_dir)

    folder = File.join(items_dir, "comme-dhabitude-claude-francois-1967")
    expect(result).to eq({ status: :created, folder: folder })
    expect(File.read(File.join(folder, "texte.md"))).to eq("")
    data = YAML.safe_load_file(File.join(folder, "data.yaml"))
    expect(data).to eq({
      "id" => "comme-dhabitude-claude-francois-1967",
      "title" => "Comme d'habitude",
      "performer" => "Claude François",
      "carnets" => [],
    })
  end

  it "ne touche à rien si le dossier existe déjà" do
    folder = File.join(items_dir, "comme-dhabitude-claude-francois-1967")
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "data.yaml"), "garde: moi\n")

    expect(IcareEditions.create_song_item(song_folder, items_dir)[:status]).to eq(:exists)
    expect(File.read(File.join(folder, "data.yaml"))).to eq("garde: moi\n")
  end

  it "refuse une fiche sans id" do
    File.write(File.join(song_folder, "c.infos"), "title: Sans id\n")

    expect(IcareEditions.create_song_item(song_folder, items_dir)[:status]).to eq(:no_id)
    expect(Dir.children(items_dir)).to be_empty
  end
end
