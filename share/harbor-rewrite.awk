# Rewrite Dockerfile FROM base images to route through a Harbor proxy-cache.
# Invoked by harbor_rewrite_dockerfile (share/build-functions.sh) as:
#   awk -v harbor=<HARBOR_REGISTRY> -f harbor-rewrite.awk <Dockerfile>
#
# Each upstream registry is mapped to its Harbor proxy-cache project (the routing
# below must match the proxy-cache projects configured in Harbor). Left untouched:
# "scratch", references to earlier build stages, images containing a $variable,
# images already pointing at <harbor>, and registries with no mapping.

BEGIN {
  # `harbor` is a Docker image-ref prefix (host[:port][/path]), so drop any URL
  # scheme/trailing slash in case HARBOR_REGISTRY was set as a full URL.
  sub(/^https?:\/\//, "", harbor)
  sub(/\/+$/, "", harbor)

  route["docker.io"]            = "dockerhub"
  route["index.docker.io"]      = "dockerhub"
  route["registry-1.docker.io"] = "dockerhub"
  route["quay.io"]              = "quay"
  route["ghcr.io"]              = "ghcr"
  route["gcr.io"]               = "gcr"
  route["registry.k8s.io"]      = "k8s"
  route["registry.gitlab.com"]  = "gitlab"
  route["docker.elastic.co"]    = "elastic"
  route["docker.tgbyte.io"]     = "tgbyte"
  route["mcr.microsoft.com"]    = "microsoft"
}

function rewrite(img,    slash, first, rest, reg, repo) {
  if (img == "" || img == "scratch") return img
  if (img in stages) return img
  if (img ~ /\$/) return img
  if (index(img, harbor "/") == 1) return img
  slash = index(img, "/")
  first = (slash > 0) ? substr(img, 1, slash - 1) : ""
  rest  = (slash > 0) ? substr(img, slash + 1) : img
  if (first != "" && (index(first, ".") > 0 || index(first, ":") > 0 || first == "localhost")) {
    reg = first; repo = rest
  } else {
    reg = "docker.io"; repo = img
  }
  if (!(reg in route)) return img
  if (reg == "docker.io" && index(repo, "/") == 0) repo = "library/" repo
  return harbor "/" route[reg] "/" repo
}

toupper($1) == "FROM" {
  imgidx = 0
  for (i = 2; i <= NF; i++) {
    if (substr($i, 1, 2) == "--") continue
    imgidx = i; break
  }
  if (imgidx > 0) {
    if (imgidx + 2 <= NF && toupper($(imgidx + 1)) == "AS") stages[$(imgidx + 2)] = 1
    newimg = rewrite($imgidx)
    if (newimg != $imgidx) {
      printf("[harbor] FROM %s -> %s\n", $imgidx, newimg) > "/dev/stderr"
      $imgidx = newimg
    }
  }
  print
  next
}

{ print }
