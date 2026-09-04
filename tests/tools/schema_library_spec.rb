# frozen_string_literal: true

require_relative "../spec_helper"
require_relative "../../tools/DiagSchem/schema_library"
require "tmpdir"

# `SchemaLibrary` — insertion d'un nouveau schéma dans `schemas.txt`. Règle dictée par
# appliquée MÉCANIQUEMENT : bémol < naturel < dièse, majeur < mineur,
# noms du plus court au plus long, une ligne vide entre chaque "type" (couple
# altération/qualité).
RSpec.describe "SchemaLibrary (insertion de schémas)" do
  describe ".alteration_rank / .quality_rank" do
    it "bémol < naturel < dièse" do
      expect(SchemaLibrary.alteration_rank("Ab7M")).to be < SchemaLibrary.alteration_rank("A7")
      expect(SchemaLibrary.alteration_rank("A7")).to be < SchemaLibrary.alteration_rank("Ad7")
    end

    it "majeur < mineur, y compris avec altération" do
      expect(SchemaLibrary.quality_rank("A")).to be < SchemaLibrary.quality_rank("Am")
      expect(SchemaLibrary.quality_rank("Ad7")).to be < SchemaLibrary.quality_rank("Adm")
    end

    it "'7M' (majeur 7e) n'est jamais pris pour un mineur" do
      expect(SchemaLibrary.quality_rank("A7M")).to eq(SchemaLibrary.quality_rank("A"))
    end
  end

  describe ".conflict" do
    let(:entries) { SchemaLibrary.parse_lines(["A-0 : 10 22/3 32/2 42/1 50 60", "Am-0 : 10 21/1 32/4 42/3 50 60"]) }

    it "refuse le même nom+case (raison :nom)" do
      expect(SchemaLibrary.conflict(entries, "A", 0, "autre chose entièrement")).to eq(:nom)
    end

    it "refuse le même schéma sous un autre nom (raison :schema, priorité si les 2)" do
      expect(SchemaLibrary.conflict(entries, "Nouveau", 9, "10 22/3 32/2 42/1 50 60")).to eq(:schema)
    end

    it "autorise un nom et un schéma tous les deux inédits" do
      expect(SchemaLibrary.conflict(entries, "B", 2, "12/1 24/4 34/3 44/2 52/1 62/1")).to be_nil
    end

    it "même nom sous une autre casse (\"a\" pour \"A\") : même refus :nom, forme canonique (bug constaté : \"c[e]-0B\" minuscule invisible de la page diags mais toujours en conflit)" do
      expect(SchemaLibrary.conflict(entries, "a", 0, "autre chose entièrement")).to eq(:nom)
    end

    it "basse entre crochets, casse différente (\"cd[e]\" vs \"Cd[E]\") : même nom canonique" do
      with_basse = SchemaLibrary.parse_lines(["Cd[E]-5 : 10 22/3 32/2 42/1 50 60"])
      expect(SchemaLibrary.conflict(with_basse, "cd[e]", 5, "autre chose entièrement")).to eq(:nom)
    end
  end

  describe ".insert" do
    it "fichier vide : la ligne seule, sans ligne vide" do
      expect(SchemaLibrary.insert("", "A", 0, "10 22/3 32/2 42/1 50 60")).to eq("A-0 : 10 22/3 32/2 42/1 50 60\n")
    end

    it "même nom, nouvelle case : rejoint le bloc existant, pas de ligne vide, case triée" do
      content = "A-0 : xxx\nA-5 : yyy\n"
      result = SchemaLibrary.insert(content, "A", 2, "zzz")
      expect(result).to eq("A-0 : xxx\nA-2 : zzz\nA-5 : yyy\n")
    end

    it "nom nouveau, même type (naturel/majeur) : rejoint le bloc, trié par longueur du nom" do
      content = "A-0 : xxx\n\nAm-0 : yyy\n"
      result = SchemaLibrary.insert(content, "A7", 0, "zzz")
      expect(result).to eq("A-0 : xxx\nA7-0 : zzz\n\nAm-0 : yyy\n")
    end

    it "nom nouveau, type différent : nouveau bloc à la bonne place, séparé par une ligne vide" do
      # Ab (bémol/majeur) puis Am (naturel/mineur) déjà présents, sans bloc naturel/majeur
      # entre les deux — "A" (naturel/majeur) doit s'insérer ENTRE, séparé des DEUX côtés.
      content = "Ab-0 : bbb\n\nAm-0 : yyy\n"
      result = SchemaLibrary.insert(content, "A", 0, "zzz")
      expect(result).to eq("Ab-0 : bbb\n\nA-0 : zzz\n\nAm-0 : yyy\n")
    end

    it "insertion en tête (bémol avant tout le reste)" do
      content = "A-0 : xxx\n\nAm-0 : yyy\n"
      result = SchemaLibrary.insert(content, "Ab", 3, "zzz")
      expect(result).to eq("Ab-3 : zzz\n\nA-0 : xxx\n\nAm-0 : yyy\n")
    end

    it "insertion en fin de fichier (dièse après tout le reste)" do
      content = "A-0 : xxx\n\nAm-0 : yyy\n"
      result = SchemaLibrary.insert(content, "Ad", 1, "zzz")
      expect(result).to eq("A-0 : xxx\n\nAm-0 : yyy\n\nAd-1 : zzz\n")
    end

    it "ne touche à AUCUNE ligne déjà présente (contenu et ordre relatif préservés ailleurs)" do
      content = "A-0 : xxx\nA-5 : yyy\n\nAm-0 : zzz\n"
      result = SchemaLibrary.insert(content, "A7M", 2, "www")
      expect(result).to include("A-0 : xxx\nA-5 : yyy\n")
      expect(result).to include("Am-0 : zzz\n")
    end
  end

  describe ".save (I/O)" do
    let(:dir) { Dir.mktmpdir }

    before { stub_const("SchemaLibrary::ASSETS", dir) }
    after { FileUtils.rm_rf(dir) }

    it "crée le dossier de la lettre et le fichier s'ils n'existent pas" do
      expect(SchemaLibrary.save("A", 0, "10 22/3 32/2 42/1 50 60")).to be_nil
      expect(File.read(SchemaLibrary.schemas_path("A"))).to eq("A-0 : 10 22/3 32/2 42/1 50 60\n")
    end

    it "refuse et n'écrit rien en cas de conflit" do
      SchemaLibrary.save("A", 0, "10 22/3 32/2 42/1 50 60")
      before = File.read(SchemaLibrary.schemas_path("A"))

      expect(SchemaLibrary.save("A", 0, "autre chose")).to eq(:nom)
      expect(File.read(SchemaLibrary.schemas_path("A"))).to eq(before)
    end
  end
end
