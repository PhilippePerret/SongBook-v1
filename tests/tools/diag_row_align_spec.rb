# frozen_string_literal: true

require_relative "../spec_helper"
require "layout"

# `diags_align` (gauche/droite/justifié/centré) : alignement des diagrammes DANS leur
# bloc — INDÉPENDANT de `diags_position` (qui place le bloc lui-même sur la page).
# `Layout.diag_row_gap`/`Layout.diag_row_x` : UNE SEULE formule, réutilisée par
# `draw_diags_row` (colonne Top/Bottom/Front), `draw_diags_grid` (page dédiée) ET la
# grille de fin de chanson (RAD7-10, `paginate_and_draw`) — avant ce fix, cette
# dernière ignorait totalement `align` (bug constaté, Carnet 1 : `diags: align: Left`
# sans effet sur les diags en trop d'une chanson en `diags_position: End`).
RSpec.describe "Layout.diag_row_gap / Layout.diag_row_x" do
  describe ".diag_row_gap" do
    it ":left/:right/:center -> gouttière FIXE (min_h_dist), jamais étirée" do
      gap = Layout.diag_row_gap(:left, 500, 3, 60)
      expect(gap).to eq(Layout.min_h_dist(:diags))
      expect(Layout.diag_row_gap(:right, 500, 3, 60)).to eq(gap)
      expect(Layout.diag_row_gap(:center, 500, 3, 60)).to eq(gap)
    end

    it ":justify -> gouttière étirée pour occuper avail_w" do
      gap = Layout.diag_row_gap(:justify, 500, 3, 60)
      expect(gap).to be > Layout.min_h_dist(:diags)
    end
  end

  describe ".diag_row_x" do
    let(:avail_w) { 500.0 }
    let(:block_w) { 200.0 }
    let(:gap) { 10.0 }

    it ":left -> collé à x0" do
      expect(Layout.diag_row_x(:left, 40.0, avail_w, block_w, gap)).to eq(40.0)
    end

    it ":right -> collé au bord droit (x0 + avail_w - block_w)" do
      expect(Layout.diag_row_x(:right, 40.0, avail_w, block_w, gap)).to eq(40.0 + avail_w - block_w)
    end

    it ":justify -> démarre après une gouttière (x0 + gap)" do
      expect(Layout.diag_row_x(:justify, 40.0, avail_w, block_w, gap)).to eq(40.0 + gap)
    end

    it ":center (ou toute autre valeur) -> centré dans avail_w" do
      expect(Layout.diag_row_x(:center, 40.0, avail_w, block_w, gap)).to eq(40.0 + (avail_w - block_w) / 2.0)
    end
  end

  # Issue #107 : `diags_position: End`, plusieurs rangées de diags avec la dernière PAS
  # pleine -> la rangée incomplète passe EN PREMIER (dessinée en haut du bloc, `rows[0]`
  # de `paginate_and_draw`), toutes les autres restent pleines — jamais pour les autres
  # positions (Top/Bot/Front), l'ORDRE des diagrammes (1..N) ne change jamais.
  describe ".diag_excess_rows (issue #107)" do
    it "End, dernière rangée incomplète : la rangée incomplète passe en 1re position" do
      paths = (1..13).to_a
      expect(Layout.diag_excess_rows(paths, 8, top_row_partial: true)).to eq([[1, 2, 3, 4, 5], (6..13).to_a])
    end

    it "\"end de l'énoncé\" : 8+5 sur 1 seule dernière ligne -> 5 en haut, 8 en dessous depuis le 6e" do
      paths = (1..13).to_a
      rows = Layout.diag_excess_rows(paths, 8, top_row_partial: true)
      expect(rows.first).to eq([1, 2, 3, 4, 5])
      expect(rows.last).to eq((6..13).to_a)
    end

    it "3 rangées, seule la dernière incomplète : incomplète en 1er, les 2 autres pleines" do
      paths = (1..20).to_a
      expect(Layout.diag_excess_rows(paths, 8, top_row_partial: true)).to eq([(1..4).to_a, (5..12).to_a, (13..20).to_a])
    end

    it "dernière rangée DÉJÀ pleine (compte multiple de cols) : rien à réordonner" do
      paths = (1..16).to_a
      expect(Layout.diag_excess_rows(paths, 8, top_row_partial: true)).to eq([(1..8).to_a, (9..16).to_a])
    end

    it "une seule rangée (compte <= cols) : inchangé" do
      paths = (1..5).to_a
      expect(Layout.diag_excess_rows(paths, 8, top_row_partial: true)).to eq([(1..5).to_a])
    end

    it "top_row_partial: false (Top/Bot/Front) : découpe normale, pleine en 1er" do
      paths = (1..13).to_a
      expect(Layout.diag_excess_rows(paths, 8, top_row_partial: false)).to eq([(1..8).to_a, (9..13).to_a])
    end
  end
end
