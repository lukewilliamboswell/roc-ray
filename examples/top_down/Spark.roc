## Collectible sparks and their circular collision rule.
import rr.Math

Spark := { id : U64, pos : Math.Vec2 }.{
	is_eq : _
	radius = 24.F32

	## Reports whether another circle touches this spark.
	hit_by : Spark, Math.Circle -> Bool
	hit_by = |spark, other| Math.circle_overlaps(other, spark_circle(spark))
}

## Returns the private circular collection body for a spark.
spark_circle : Spark -> Math.Circle
spark_circle = |spark| Math.circle(spark.pos, Spark.radius)
