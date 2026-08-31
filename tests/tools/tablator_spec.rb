# frozen_string_literal: true

require_relative "../spec_helper"
require_relative "../../tools/tablator/tablator"

# Tests des outils
RSpec.describe "outil tablator (rendu SVG direct)" do
  it "Refuser un texte de tablature illisible" do
    expect { Tablator.parse_event("n'importe quoi", "4") }
      .to raise_error(Tablator::ParseError)
  end

  it "Regrouper les tokens en mesures réelles (accumulation de durée contre la métrique)" do
    measures, target = Tablator.parse_measures(%w[50/4 51/4 52/4 53/4 54/4], "4/4", chord_names: false)
    expect(target).to eq(4.0)
    expect(measures.size).to eq(2)
    expect(measures[0][:events].size).to eq(4)
    expect(measures[1][:events].size).to eq(1)
  end

  it "Une barre explicite force une coupure même mesure incomplète" do
    measures, = Tablator.parse_measures(%w[50/4 |], "4/4", chord_names: false)
    expect(measures.size).to eq(1)
    expect(measures[0][:events].size).to eq(1)
  end

  it "Nom d'accord explicite [Nom] prime sur le calcul auto" do
    measures, = Tablator.parse_measures(["[Am7]", "<10 21>/4"], "4/4", chord_names: true)
    expect(measures[0][:label]).to eq("Am7")
  end

  it "Deviner le nom d'un accord depuis les notes (2 cordes ou plus)" do
    measures, = Tablator.parse_measures(["<10 21 32>/4"], "4/4", chord_names: true)
    expect(measures[0][:label]).not_to be_nil
  end

  it "Produire un SVG par système, avec les dimensions attendues" do
    content = "---\ntitle: Test\nmetrique: 4/4\n---\n50/4 51/4 52/4 53/4\n"
    systems = Tablator.render_tab_svg(content, measures_per_line: 4)
    expect(systems.size).to eq(1)
    result = systems.first
    expect(result[:svg]).to include("<svg")
    expect(result[:svg]).to include('width="')
    expect(result[:width_pt]).to be > 0
    expect(result[:height_pt]).to be > 0
  end

  it "measures_per_line plus petit que le nombre de mesures produit plusieurs systèmes indépendants " do
    content = "50/4 51/4 52/4 53/4 54/4 55/4 56/4 57/4\n" # 2 mesures réelles en 4/4
    two_systems = Tablator.render_tab_svg(content, measures_per_line: 1)
    single_system = Tablator.render_tab_svg(content, measures_per_line: 999)
    expect(two_systems.size).to eq(2)
    expect(single_system.size).to eq(1)
  end

  it "Un système s'arrête à SES mesures (largeur), jamais à la largeur d'un système complet" do
    content = "50/4 51/4 52/4 53/4 54/4 55/4 56/4 57/4\n" # 2 mesures réelles en 4/4
    systems = Tablator.render_tab_svg(content, measures_per_line: 2)
    full = systems.first[:width_pt]
    partial = Tablator.render_tab_svg("50/4 51/4 52/4 53/4\n", measures_per_line: 2).first[:width_pt]
    expect(partial).to be < full
  end

  it "Affiche les chiffres corde:case dans le SVG produit" do
    content = "60/4\n"
    result = Tablator.render_tab_svg(content, measures_per_line: 4).first
    expect(result[:svg]).to include(">0<")
  end

  it "Pas de barre de mesure en tout début de système (à x = TIME_SIG_W)" do
    content = "60/4\n"
    result = Tablator.render_tab_svg(content, measures_per_line: 4).first
    leading_bar = result[:svg].scan(/<line x1="(#{Regexp.escape(Tablator.param(:time_sig_w).to_s)})" y1="[\d.]+" x2="\1"/)
    expect(leading_bar).to be_empty
  end

  it "Une noire a une hampe (sans crochet)" do
    result = Tablator.render_tab_svg("60/4\n", measures_per_line: 4).first
    expect(result[:svg]).to include("<line")
  end

  describe "doigtés (main droite p/i/m/a/c + main gauche chiffre)" do
    it "main droite seule" do
      ev = Tablator.parse_event("60/4-p", "4")
      expect(ev.rh).to eq("p")
      expect(ev.lh).to be_nil
    end

    it "main gauche seule" do
      ev = Tablator.parse_event("60/4-2", "4")
      expect(ev.lh).to eq("2")
    end

    it "les deux combinés" do
      ev = Tablator.parse_event("60/4-p2", "4")
      expect(ev.rh).to eq("p")
      expect(ev.lh).to eq("2")
    end

    it "doigté sans durée explicite (reprend la dernière durée)" do
      ev = Tablator.parse_event("60-p2", "8")
      expect(ev.denom).to eq(8)
      expect(ev.rh).to eq("p")
    end
  end

  describe "hammer-on/pull-off (issue #39, marque en préfixe sur la note qui sonne)" do
    it "hammer-on : case supérieure à la précédente occurrence de la corde" do
      ev = Tablator.parse_event("h52/4", "4", { 5 => 0 })
      expect(ev.link).to eq(:hammer)
      expect(ev.notes).to eq([{ corde: 5, case: 2 }])
    end

    it "pull-off : case inférieure à la précédente occurrence de la corde" do
      ev = Tablator.parse_event("p50/4", "4", { 5 => 2 })
      expect(ev.link).to eq(:pull)
    end

    it "refuse un hammer-on sans occurrence précédente de la corde" do
      expect { Tablator.parse_event("h52/4", "4", {}) }.to raise_error(Tablator::ParseError)
    end

    it "refuse un hammer-on vers une case inférieure ou égale" do
      expect { Tablator.parse_event("h50/4", "4", { 5 => 2 }) }.to raise_error(Tablator::ParseError)
    end

    it "refuse un pull-off vers une case supérieure ou égale" do
      expect { Tablator.parse_event("p52/4", "4", { 5 => 0 }) }.to raise_error(Tablator::ParseError)
    end

    it "la corde peut avoir sonné dans un accord, pas seulement en note seule" do
      measures, = Tablator.parse_measures(["<50 61>/4", "h52/4"], "4/4", chord_names: false)
      events = measures.flat_map { |m| m[:events] }
      expect(events.last.link).to eq(:hammer)
    end

    it "la corde peut avoir sonné plusieurs notes plus tôt (pas forcément l'événement immédiat)" do
      measures, = Tablator.parse_measures(%w[50/4 61/4 31/4 h52/4], "4/4", chord_names: false)
      events = measures.flat_map { |m| m[:events] }
      expect(events.last.link).to eq(:hammer)
    end

    it "dessine un arc + lettre H/P dans le SVG produit" do
      result = Tablator.render_tab_svg("50/4 h52/4\n", measures_per_line: 4).first
      expect(result[:svg]).to include("<path")
      expect(result[:svg]).to include(">H<")
    end
  end
end
