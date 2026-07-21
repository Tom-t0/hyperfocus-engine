"""消化実績ログ。休日の自動消費判定（進捗ゼロ日の検出）に使う。"""
from django.db import models


class ProgressQuerySet(models.QuerySet):
    def aggregate_total(self) -> int:
        return self.aggregate(t=models.Sum("amount"))["t"] or 0


class ProgressLog(models.Model):
    task = models.ForeignKey(
        "tasks.Task", on_delete=models.CASCADE, related_name="progress_logs"
    )
    amount = models.PositiveIntegerField()
    logical_date = models.DateField(db_index=True)  # アプリ上の「今日」（動的境界を反映）
    created_at = models.DateTimeField(auto_now_add=True)

    objects = ProgressQuerySet.as_manager()

    class Meta:
        ordering = ["-created_at"]
