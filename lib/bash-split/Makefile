.PHONY: build test clean

build: dist/bash-split

dist/bash-split: main.go go.mod go.sum
	mkdir -p dist
	go build -o dist/bash-split .

test: dist/bash-split
	./dist/bash-split --test

clean:
	rm -rf dist
