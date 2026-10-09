# Build the systems notes from this directory.
#   make
#   make pycore_diagrams.pdf

.PHONY: all clean

all: pycore_diagrams.pdf call_fsm.pdf

pycore_diagrams.pdf: pycore_diagrams.tex figures/tikz_styles.tex figures/fig_*.tex
	pdflatex -interaction=nonstopmode pycore_diagrams.tex
	pdflatex -interaction=nonstopmode pycore_diagrams.tex

call_fsm.pdf: call_fsm.tex
	pdflatex -interaction=nonstopmode call_fsm.tex
	pdflatex -interaction=nonstopmode call_fsm.tex

clean:
	rm -f *.aux *.log *.out *.toc *.lof *.lot
