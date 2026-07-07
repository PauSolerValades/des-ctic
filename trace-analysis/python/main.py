import polars as pl
import powerlaw


def main():

# powerlaw_fit()


def powerlaw_fit():

    df = pl.read_parquet("../dataset-creation/data/post_metrics.parquet")
    print(df.shape)
    print(df.columns)

    reposts_df = df.select(["run_id", "post_id", "total_reposts"])
    sorted_reposts = reposts_df.sort(
        ["run_id", "total_reposts", "post_id"], descending=[False, True, False]
    )

    print(sorted_reposts.filter(pl.col("run_id") == 0).head(20))

    nonzero = df.filter(pl.col("total_reposts") >= 1)
    groups = nonzero.group_by("run_id").agg(pl.col("total_reposts"))

    results = []
    for row in groups.sort("run_id").iter_rows():
        run_id = row[0]
        reposts = row[1]
        fit = powerlaw.Fit(reposts, discrete=True, verbose=False)
        results.append(
            {
                "run_id": run_id,
                "n_nonzero": len(reposts),
                "alpha": fit.alpha,
                "xmin": fit.xmin,
                "sigma": fit.sigma,
            }
        )

    alpha_df = pl.DataFrame(results).sort("run_id")
    print(alpha_df)

    print(
        f"\nMean α: {alpha_df['alpha'].mean():.4f}  "
        f"|  Std: {alpha_df['alpha'].std():.4f}  "
        f"|  Min: {alpha_df['alpha'].min():.4f}  "
        f"|  Max: {alpha_df['alpha'].max():.4f}"
    )


if __name__ == "__main__":
    main()
