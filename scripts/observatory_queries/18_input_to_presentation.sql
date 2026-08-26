SELECT subject_id,parent_id,cycle,duration_ns FROM structural_latency WHERE kind=1 AND name='input_to_presentation' ORDER BY duration_ns DESC,id;
