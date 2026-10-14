# GitHub Style Generator

The generated `MacDown/Resources/Styles/GitHub-2020.css` is committed so normal
app builds do not need Node.js. To regenerate it with the pinned Dart Sass tools:

```sh
npm ci
make
```

Commit the stylesheet with changes to the generator or dependency lockfile.
