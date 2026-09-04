# frozen_string_literal: true

require_relative "../spec_helper"
require "diags_page"

# `DiagsPage.grid` — légende affichée vs texte copié pour un accord avec basse entre
# crochets (`.lyr` : crochets ; affichage : slash + solfège italien, `Layout.display_chord`,
# même règle partout).
RSpec.describe "DiagsPage.grid (basse en solfège italien, jamais les crochets)" do
  it "légende en solfège italien slash (\"C/mi\"), presse-papier en syntaxe .lyr (crochets)" do
    html = DiagsPage.grid([{ file: "/tmp/x/C[E]-0B.svg" }])
    expect(html).to include('data-copy="/C[E]-0B:"')
    expect(html).to include("<figcaption>/C/mi-0B:</figcaption>")
  end

  it "nom enregistré en minuscule (\"c[e]-0B\") : légende et presse-papier normalisés quand même" do
    html = DiagsPage.grid([{ file: "/tmp/x/c[e]-0B.svg" }])
    expect(html).to include('data-copy="/C[E]-0B:"')
    expect(html).to include("<figcaption>/C/mi-0B:</figcaption>")
  end
end
