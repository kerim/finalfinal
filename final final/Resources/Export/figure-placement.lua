-- Pin every LaTeX figure to its exact position in the document ([H], via the
-- `float` package — see float-package.tex) instead of letting LaTeX float it
-- forward past following text when it doesn't fit on the current page. PDF
-- export only (see ExportService.swift): other writers ignore attributes
-- they don't recognize, so this is harmless if ever applied elsewhere, but
-- it's only wired in for the PDF path.
function Figure(fig)
  fig.attr.attributes["latex-placement"] = "H"
  return fig
end
