#include <stdlib.h>
#include <limits.h>
#include <lua.h>
#include <lauxlib.h>
#include <assimp/cimport.h>
#include <assimp/scene.h>
#include "../helper.h"

struct mesh3D
{
    unsigned int* indices;
    size_t numTris;
    struct aiVector3D* verts;
    size_t numVerts;
    struct aiVector3D* normals;
};

struct tri3D
{
    struct aiVector3D vert0;
    struct aiVector3D vert1;
    struct aiVector3D vert2;
};

struct aiVector3D new_vec3d(float x, float y, float z)
{
    struct aiVector3D result;
    result.x = x;
    result.y = y;
    result.z = z;
    return result;
}

struct tri3D new_tri3d(struct aiVector3D v0, struct aiVector3D v1, struct aiVector3D v2)
{
    struct tri3D result;
    result.vert0 = v0;
    result.vert1 = v1;
    result.vert2 = v2;
    return result;
}

float indexVector3D(struct aiVector3D vec, int index)
{
    switch (index)
    {
        case 0:
            return vec.x;
        case 1:
            return vec.y;
        case 2:
            return vec.z;
        default:
            puts("Warning: vector index out of bounds");
            return 0.0f;
    }
}

struct aiVector3D addVector3D(struct aiVector3D left, struct aiVector3D right)
{
    struct aiVector3D result;
    result.x = left.x + right.x;
    result.y = left.y + right.y;
    result.z = left.z + right.z;
    return result;
}

struct aiVector3D subVector3D(struct aiVector3D left, struct aiVector3D right)
{
    struct aiVector3D result;
    result.x = left.x - right.x;
    result.y = left.y - right.y;
    result.z = left.z - right.z;
    return result;
}

struct aiVector3D mulVector3D(struct aiVector3D left, float right)
{
    struct aiVector3D result;
    result.x = left.x * right;
    result.y = left.y * right;
    result.z = left.z * right;
    return result;
}

struct aiVector3D mulVector3D3D(struct aiVector3D left, struct aiVector3D right)
{
    struct aiVector3D result;
    result.x = left.x * right.x;
    result.y = left.y * right.y;
    result.z = left.z * right.z;
    return result;
}

struct aiVector3D minVector3D(struct aiVector3D left, struct aiVector3D right)
{
    struct aiVector3D min;
    min.x = left.x < right.x ? left.x : right.x;
    min.y = left.y < right.y ? left.y : right.y;
    min.z = left.z < right.z ? left.z : right.z;
    return min;
}

struct aiVector3D maxVector3D(struct aiVector3D left, struct aiVector3D right)
{
    struct aiVector3D max;
    max.x = left.x > right.x ? left.x : right.x;
    max.y = left.y > right.y ? left.y : right.y;
    max.z = left.z > right.z ? left.z : right.z;
    return max;
}

struct aiVector3D centerTri3D(struct tri3D tri)
{
    return mulVector3D(addVector3D(addVector3D(tri.vert0, tri.vert1), tri.vert2), 1 / 3.0f);
}

void writevec(struct aiVector3D vec, FILE* file)
{
    float data[] = {
        vec.x, vec.y, vec.z
    };
    fwrite(data, sizeof(float), sizeof(data) / sizeof(float), file);
}

void writetri(struct tri3D tri, FILE* file)
{
    float data[] = {
        tri.vert0.x, tri.vert0.y, tri.vert0.z,
        tri.vert1.x, tri.vert1.y, tri.vert1.z,
        tri.vert2.x, tri.vert2.y, tri.vert2.z
    };
    fwrite(data, sizeof(float), sizeof(data) / sizeof(float), file);
}

struct mesh3D makeTriList(const struct aiScene* scene)
{
    if (scene->mNumMeshes > 1)
    {
        puts(">1 meshes not supported, only taking the first one");
    }
    const struct aiMesh* mesh = scene->mMeshes[0];
    struct mesh3D result;
    result.numVerts = mesh->mNumVertices;
    result.numTris = 0;
    for (size_t i = 0; i < mesh->mNumFaces; i++)
        result.numTris += mesh->mFaces[i].mNumIndices - 2;
    result.verts = mesh->mVertices;
    result.normals = mesh->mNormals;
    result.indices = malloc_s(result.numTris * 3 * sizeof(unsigned int));
    result.numTris = 0;
    for (size_t i = 0; i < mesh->mNumFaces; i++)
    {
        struct aiFace face = mesh->mFaces[i];
        switch (face.mNumIndices)
        {
            case 3:
                result.indices[result.numTris * 3 + 0] = face.mIndices[0];
                result.indices[result.numTris * 3 + 1] = face.mIndices[1];
                result.indices[result.numTris * 3 + 2] = face.mIndices[2];
                result.numTris++;
                break;
            case 4:
                result.indices[result.numTris * 3 + 0] = face.mIndices[0];
                result.indices[result.numTris * 3 + 1] = face.mIndices[1];
                result.indices[result.numTris * 3 + 2] = face.mIndices[2];
                result.numTris++;
                result.indices[result.numTris * 3 + 0] = face.mIndices[0];
                result.indices[result.numTris * 3 + 1] = face.mIndices[2];
                result.indices[result.numTris * 3 + 2] = face.mIndices[3];
                result.numTris++;
                break;
            default:
                printf("Face had %d verts, only 3/4 supported; skipping\n", face.mNumIndices);
                break;
        }
    }
    return result;
}

void writeVerts(FILE* file, struct mesh3D mesh)
{
    for (size_t i = 0; i < mesh.numVerts; i++)
        writevec(mesh.verts[i], file);
}

void writeNormals(FILE* file, struct mesh3D mesh)
{
    for (size_t i = 0; i < mesh.numVerts; i++)
        writevec(mesh.normals[i], file);
}

struct tri3D tri3dFromMesh(struct mesh3D mesh, size_t n)
{
    return new_tri3d(
            mesh.verts[mesh.indices[n * 3 + 0]],
            mesh.verts[mesh.indices[n * 3 + 1]],
            mesh.verts[mesh.indices[n * 3 + 2]]);
}

float findMidpoint(struct mesh3D tris, int* axis)
{
    struct aiVector3D mean = new_vec3d(0, 0, 0);
    struct aiVector3D M2 = new_vec3d(0, 0, 0);
    for (size_t n = 0; n < tris.numTris; n++)
    {
        struct aiVector3D center = centerTri3D(tri3dFromMesh(tris, n));
        struct aiVector3D delta = subVector3D(center, mean);
        mean = addVector3D(mean, mulVector3D(delta, 1.0f / (n + 1)));
        M2 = addVector3D(M2, mulVector3D3D(delta, subVector3D(center, mean)));
    }
    struct aiVector3D variance = mulVector3D(M2, 1.0f / (tris.numTris - 1));
    if (variance.x > variance.y && variance.x > variance.z)
    {
        *axis = 0;
        return mean.x;
    }
    else if (variance.y > variance.z)
    {
        *axis = 1;
        return mean.y;
    }
    else
    {
        *axis = 2;
        return mean.z;
    }
}

// *less and *greater return malloc'ed objects
void splitTris(struct mesh3D tris, float split, int axis,
        struct mesh3D* less, struct mesh3D* greater)
{
    less->numVerts = tris.numVerts;
    greater->numVerts = tris.numVerts;
    less->verts = tris.verts;
    greater->verts = tris.verts;
    less->normals = tris.normals;
    greater->normals = tris.normals;
    less->numTris = 0;

    for (size_t i = 0; i < tris.numTris; i++)
        if (indexVector3D(centerTri3D(tri3dFromMesh(tris, i)), axis) < split)
            less->numTris++;
    greater->numTris = tris.numTris - less->numTris;
    less->indices = malloc_s(less->numTris * 3 * sizeof(int));
    greater->indices = malloc_s(greater->numTris * 3 * sizeof(int));
    less->numTris = 0;
    greater->numTris = 0;
    for (size_t i = 0; i < tris.numTris; i++)
    {
        if (indexVector3D(centerTri3D(tri3dFromMesh(tris, i)), axis) < split)
        {
            less->indices[less->numTris * 3 + 0] = tris.indices[i * 3 + 0];
            less->indices[less->numTris * 3 + 1] = tris.indices[i * 3 + 1];
            less->indices[less->numTris * 3 + 2] = tris.indices[i * 3 + 2];
            less->numTris++;
        }
        else
        {
            greater->indices[greater->numTris * 3 + 0] = tris.indices[i * 3 + 0];
            greater->indices[greater->numTris * 3 + 1] = tris.indices[i * 3 + 1];
            greater->indices[greater->numTris * 3 + 2] = tris.indices[i * 3 + 2];
            greater->numTris++;
        }
    }
}

void splitTrisAuto(struct mesh3D tris,
        struct mesh3D* less, struct mesh3D* greater)
{
    int axis;
    float midpoint = findMidpoint(tris, &axis);
    splitTris(tris, midpoint, axis, less, greater);
}

void writeBbox(FILE* file, struct mesh3D mesh)
{
    struct aiVector3D min;
    struct aiVector3D max;
    for (size_t i = 0; i < mesh.numTris; i++)
    {
        struct tri3D tri = tri3dFromMesh(mesh, i);
        min = minVector3D(min, tri.vert0);
        min = minVector3D(min, tri.vert1);
        min = minVector3D(min, tri.vert2);
        max = maxVector3D(max, tri.vert0);
        max = maxVector3D(max, tri.vert1);
        max = maxVector3D(max, tri.vert2);
    }
    //printf("%f %f %f %f %f %f\n", min.x, min.y, min.z, max.z, max.y, max.z);
    writevec(min, file);
    writevec(max, file);
}

long writeTris(FILE* file, struct mesh3D tris, long gotoDone)
{
    if (tris.numTris == 0)
    {
        puts("Warning: writeTris() count == 0");
        return 0;
    }
    if (tris.numTris < 5)
    {
        long tell = ftell(file);
        fwrite(&tris.numTris, sizeof(int), 1, file);
        fwrite(&gotoDone, sizeof(int), 1, file);
        fwrite(tris.indices, sizeof(int), tris.numTris * 3, file);
        return tell;
    }
    struct mesh3D less;
    struct mesh3D greater;
    splitTrisAuto(tris, &less, &greater);
    long lessFile = writeTris(file, less, gotoDone);
    long greaterFile = writeTris(file, greater, lessFile);
    long currentFile = ftell(file);
    int zero = 0;
    fwrite(&zero, sizeof(int), 1, file);
    writeBbox(file, tris);
    int offsets[] = { (int)gotoDone, (int)greaterFile };
    fwrite(offsets, sizeof(int), sizeof(offsets) / sizeof(int), file);
    free(less.indices);
    free(greater.indices);
    return currentFile;
}

int run_loadtris(lua_State* state)
{
    const char* objfile = luaL_checkstring(state, 1);
    const char* outputFilename = "tris.dat";

    const struct aiScene* scene = aiImportFile(objfile, 0);
    if (!scene)
        luaL_error(state, "Failed to load model: %s", aiGetErrorString());

    puts("Making tri list");
    struct mesh3D unpacked = makeTriList(scene);

    FILE* output = fopen(outputFilename, "wb");

    long begin = ftell(output);
    fseek(output, sizeof(int) * 3, SEEK_CUR);

    long verts = ftell(output);
    writeVerts(output, unpacked);

    long normals = ftell(output);
    writeNormals(output, unpacked);

    puts("Writing tri list");
    long finalStreamPos = writeTris(output, unpacked, 0);
    if (finalStreamPos > INT_MAX)
    {
        luaL_error(state, "Filesize greater than 2 gigabytes, cannot use i32 offsets");
    }

    fseek(output, begin, SEEK_SET);
    int header[] = { (int)finalStreamPos, (int)verts, (int)normals };
    fwrite(header, sizeof(int), 3, output);

    free(unpacked.indices);
    aiReleaseImport(scene);

    fclose(output);

    printf("Wrote %ld bytes for %ld triangles\n", finalStreamPos, unpacked.numVerts);

    lua_pushstring(state, outputFilename);
    return 1;
}

int maketris(lua_State* state)
{
    lua_register(state, "maketris", run_loadtris);
    return 0;
}
