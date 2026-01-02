module [RocMatrix, Matrix, identity, from_matrix, to_matrix, ]
Matrix : {
    m0 : F32, m4 : F32, m8 : F32, m12 : F32,
    m1 : F32, m5 : F32, m9 : F32, m13 : F32,
    m2 : F32, m6 : F32, m10 : F32, m14 : F32,
    m3 : F32, m7 : F32, m11 : F32, m15 : F32,
}
RocMatrix := {
    m0 : F32, m4 : F32, m8 : F32, m12 : F32,
    m1 : F32, m5 : F32, m9 : F32, m13 : F32,
    m2 : F32, m6 : F32, m10 : F32, m14 : F32,
    m3 : F32, m7 : F32, m11 : F32, m15 : F32,
}
from_matrix :
    {
        m0 : F32, m4 : F32, m8 : F32, m12 : F32,
        m1 : F32, m5 : F32, m9 : F32, m13 : F32,
        m2 : F32, m6 : F32, m10 : F32, m14 : F32,
        m3 : F32, m7 : F32, m11 : F32, m15 : F32,
    }
    -> RocMatrix
from_matrix = |matrix|
    @RocMatrix(matrix)

to_matrix = |@RocMatrix(matrix)| matrix
identity : Matrix
identity =  {
    m0 : 1, m4 : 0, m8 : 0, m12 : 0,
    m1 : 0, m5 : 1, m9 : 0, m13 : 0,
    m2 : 0, m6 : 0, m10 : 1, m14 : 0,
    m3 : 0, m7 : 0, m11 : 0, m15 : 1,
}
