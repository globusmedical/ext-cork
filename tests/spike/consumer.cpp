#include <cork.h>

int main() {
  static_assert(sizeof(uint) == 4, "Cork requires 32-bit indices");
  static_assert(sizeof(CorkTriMesh) == 24, "Unexpected x64 CorkTriMesh layout");

  typedef void (*Operation)(CorkTriMesh, CorkTriMesh, CorkTriMesh *);
  Operation volatile operations[] = {
      &computeUnion, &computeDifference, &computeIntersection,
      &computeSymmetricDifference, &resolveIntersections};
  for (unsigned int index = 0; index < 5; ++index) {
    if (operations[index] == nullptr) {
      return 1;
    }
  }
  bool (*volatile solid)(CorkTriMesh) = &isSolid;
  if (solid == nullptr) {
    return 2;
  }

  CorkTriMesh mesh = {};
  freeCorkTriMesh(&mesh);
  return mesh.n_triangles != 0 || mesh.n_vertices != 0 ||
         mesh.triangles != nullptr || mesh.vertices != nullptr;
}
