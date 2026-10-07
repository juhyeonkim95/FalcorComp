// Links the author's name in the footer's copyright line (Furo prints the copyright as plain text).
document.addEventListener("DOMContentLoaded", () => {
  const name = "Juhyeon Kim";
  const url = "https://juhyeonkim.netlify.app/";
  for (const element of document.querySelectorAll(".bottom-of-page .copyright")) {
    const html = element.innerHTML;
    if (html.includes(name) && !element.querySelector("a.author-link"))
      element.innerHTML = html.replace(name, `<a class="author-link" href="${url}">${name}</a>`);
  }
});
