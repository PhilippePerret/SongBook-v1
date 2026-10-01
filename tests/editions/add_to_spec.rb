# frozen_string_literal: true

require_relative "../spec_helper"
require "song_adder"
require "tmpdir"
require "yaml"

RSpec.describe "add-to : ajout d'une chanson à un carnet" do
  let(:tmp) { Dir.mktmpdir }
  let(:carnet) { File.join(tmp, "Carnet-test") }
  let(:tdm) { File.join(carnet, "cc.tdm") }

  before { FileUtils.mkdir_p(carnet) }
  after { FileUtils.rm_rf(tmp) }

  describe "table des matières" do
    it "insère l'id dans l'ordre alphabétique, avant le premier id supérieur" do
      File.write(tdm, "- aigle-noir-barbara-1970\n- cest-ecrit-francis-cabrel-1988\n\n- zorro-x-1990\n")

      expect(SongAdder.add_to_tdm(carnet, "bicyclette-yves-montand-1968")).to be true
      expect(File.read(tdm)).to eq("- aigle-noir-barbara-1970\n- bicyclette-yves-montand-1968\n- cest-ecrit-francis-cabrel-1988\n\n- zorro-x-1990\n")
    end

    it "ajoute en fin de liste si aucun id n'est supérieur" do
      File.write(tdm, "- aigle-noir-barbara-1970\n")

      SongAdder.add_to_tdm(carnet, "zz-top-1980")
      expect(File.read(tdm)).to eq("- aigle-noir-barbara-1970\n- zz-top-1980\n")
    end

    it "ne double pas une chanson déjà présente" do
      File.write(tdm, "- aigle-noir-barbara-1970\n")

      expect(SongAdder.add_to_tdm(carnet, "aigle-noir-barbara-1970")).to be false
      expect(File.read(tdm)).to eq("- aigle-noir-barbara-1970\n")
    end
  end

  describe "identifiant du carnet" do
    it "lit le champ id de la fiche" do
      File.write(File.join(carnet, "cc.infos"), "id: carnet-full\ntitle: Tout\n")

      expect(SongAdder.ensure_carnet_id(carnet)).to eq("carnet-full")
    end

    it "le demande et l'ajoute en tête de fiche s'il manque" do
      File.write(File.join(carnet, "cc.infos"), "title: Tout\n")
      prompt = instance_double(TTY::Prompt)
      allow(SongAdder).to receive(:colored_prompt).and_return(prompt)
      allow(prompt).to receive(:ask).with(SongAdder.yellow("Identifiant du carnet :"), default: "carnet-test").and_return("carnet-full")

      expect(SongAdder.ensure_carnet_id(carnet)).to eq("carnet-full")
      expect(File.read(File.join(carnet, "cc.infos"))).to eq("id: carnet-full\ntitle: Tout\n")
    end
  end

  describe "donnée carnets du site des éditions" do
    it "ajoute le carnet en gardant les autres données, sans doublon" do
      File.write(File.join(tmp, "data.yaml"), "---\nid: x\ntitle: X\ncarnets: ['a']\nslug: s\n")

      expect(IcareEditions.add_carnet(tmp, "b")).to be true
      expect(IcareEditions.add_carnet(tmp, "b")).to be false
      expect(YAML.safe_load_file(File.join(tmp, "data.yaml"))).to eq({ "id" => "x", "title" => "X", "carnets" => %w[a b], "slug" => "s" })
    end
  end
end
